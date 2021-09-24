>
# test demo of upgrade using pglogical_create_subscriber

# Requirements:
# PostgreSQL 10 and 13 installed
# pglogical installed for both version

# PGDG/Redhat style binary paths
BIN10=/usr/pgsql-10/bin
BIN13=/usr/pgsql-13/bin

# directories we will use
SOURCE=source
DEST=dest
NDEST=ndest

# setup database to be upgraded

$BIN10/initdb $SOURCE

cat >> $SOURCE/postgresql.conf <<-'EOF'
	port = 9432
	unix_socket_directories = '/tmp'
	shared_preload_libraries = 'pglogical'
	wal_level = 'logical'
	max_worker_processes = 10   # one per database needed on provider node
                            # one per node needed on subscriber node
	max_replication_slots = 10  # one per node needed on provider node
	max_wal_senders = 10        # one per node needed on provider node
	track_commit_timestamp = on
	wal_keep_segments = 100
EOF

$BIN10/pg_ctl -D $SOURCE -l source-log -w start

SRCCON="-h /tmp -p 9432"
DSTCON="-h /tmp -p 9433"
DB="testdb"

# set up and start a standby replica

$BIN10/pg_basebackup $SRCCON -D $DEST -R -x

sed -i s/9432/9433/ $DEST/postgresql.conf

$BIN10/pg_ctl -D $DEST -l dest-log start

# make the database on the original, add some data

$BIN10/createdb $SRCCON $DB

FIXSQL="alter table pgbench_history add hid serial primary key"
$BIN10/pgbench $SRCCON -i --foreign-keys -s 10 $DB
$BIN10/psql $SRCCON -c "$FIXSQL" $DB
$BIN10/pgbench $SRCCON -c 8 -j 4 -T 20 $DB


# set up pglogical, add the tables

$BIN10/psql $SRCCON -c "create extension pglogical" $DB
$BIN10/psql $SRCCON -c " SELECT pglogical.create_node(node_name := 'provider', dsn := 'host=/tmp port=9432 dbname=testdb')" $DB
$BIN10/psql $SRCCON -c "SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);" $DB
$BIN10/psql $SRCCON -c "SELECT pglogical.replication_set_add_all_sequences('default', ARRAY['public']);" $DB

# now stop the standby

sleep 5 # first give the standby time to catch up

$BIN10/pg_ctl -D $DEST stop


# stack up some more stuff so there is something to catch up

$BIN10/pgbench $SRCCON -c 8 -j 4 -T 20 $DB

# convert the standby to a promoted server, as a logical subscriber

$BIN10/pglogical_create_subscriber -D $DEST \
	--subscriber-name='upgradesub' \
	--provider-dsn="dbname=$DB host=/tmp port=9432" \
	--subscriber-dsn="dbname=$DB host=/tmp port=9433" \
	--replication-sets='default' -v

# get the replication origin name - pg_upgrade will wipe it out

RONAME=`$BIN10/bin/psql $DSTCON -A -X -t -c "select roname from pg_replication_origin" $DB`

# stop the logical subscriber

$BIN10/pg_ctl -D $DEST stop

# create the upgrade destination

$BIN13/initdb $NDEST

cat >> $NDEST/postgresql.conf <<-'EOF'
	port = 9433
	unix_socket_directories = '/tmp'
	shared_preload_libraries = 'pglogical'
	wal_level = 'logical'
	max_worker_processes = 10   # one per database needed on provider node
                            # one per node needed on subscriber node
	max_replication_slots = 10  # one per node needed on provider node
	max_wal_senders = 10        # one per node needed on provider node
	track_commit_timestamp = on
	wal_keep_segments = 100
EOF

# upgrade and start the pglogical subscriber

$BIN13/pg_upgrade -b $BIN10 -B $BIN13 -d $DEST -D $NDEST -k

$BIN13/pg_ctl -D $NDEST -l dest-log -w start

# restore the replication origin name

$BIN13/psql $DSTCON -c "select pg_replication_origin_create('$RONAME')" $DB

sleep 30 # wait for connection to be established

# flush the replicated sequence

$BIN10/psql $SRCCON -c "select pglogical.synchronize_sequence('public.pgbench_history_hid_seq')" $DB

# let's see what the state of replication is
# we're looking for a state of "streaming" here

$BIN10/psql $SRCCON -x -c "select * from pg_stat_replication where application_name = 'upgradesub'" $DB












