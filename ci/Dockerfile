FROM centos:7

RUN yum install -y epel-release

RUN yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

RUN yum install -y \
	postgresql10 postgresql10-server pglogical_10 \
	postgresql13 postgresql13-server pglogical_13
