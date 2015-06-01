#!/bin/bash
# Script to create Mozilla NSS certificates for openLDAP
# Install packages needed and configure server
# If installing client and server on a separate machine migrationtools,openldap-servers and migrationtools are not
# needed on the client machine and openldap-clients, sssd, authconfig are not needed on server
# Lots of things I could probably do better, rewrite in python maybe
# Todo - add this to a kickstart file, include the changes.ldif and base.ldif creation in the script

yum -y install openldap openldap-servers openldap-clients migrationtools nss-utils sssd authconfig authconfig-gtk

# This is way more than what is needed for setting networkingl I borrowed from another script I worked on
# and didnt feel like cutting it down

hostnamectl set-hostname instructor.example.com

echo "Determining host networking...."
for netw in $(ip addr show | grep ^[0-9] | cut -d' ' -f2)
do
case $netw in
	lo:)
		ping -c 1 127.0.0.1 > /dev/null
		[ $? -eq 0 ] && echo "localhost ok" || { echo "localhost not ok"; exit 1; } ;;
	eth[0-9]:)
		ipadrss=`ip addr show $netw | awk '/inet/{ print $2;exit; }' | cut -d"/" -f1` 
		ethdev=$netw
		ping -c 1 $ipadrss > /dev/null
		[ $? -eq 0 ] && echo "ethernet ok" || { echo "ethernet not ok"; exit 1; }
		echo "IP Address of host stored as $ipadrss"
		nmcli c mod $ethdev ipv4.method auto ipv4.addresses "$ipadrss/24"
		echo $? " is exit status of nmcli command"
		echo "Configured $ethdev for static ip $ipaddrss/24 "
		echo "$lo instructor.example.com" >> /etc/hosts
		echo "$ethdev instructor.example.com" >> /etc/hosts
		cat /etc/hosts;;
	br[0-100]:)
		echo "Bridged ethernet present"
		brdev=$netw
		bripadrss=`ip addr show $netw | awk '/inet/{ print $2;exit; }' | cut -d'/' -f1`
		ping -c 1 $bripadrss > /dev/null
		[ $? -eq 0 ] && echo "bridged ethernet ok" || { echo "bridged ethernet not ok"; exit 1; }
		echo "Ethernet Bridge IP address stored as $bripadrss";;
	virbr[0-100]:)
		echo "Virtual Bridge ethernet present"
		virdev=$netw
		vbripadrss=`ip addr show $netw | awk '/inet/{ print $2;exit; }' | cut -d'/' -f1`
		ping -c 1 $vbripadrss > /dev/null
		[ $? -eq 0 ] && echo "Virtual bridged ethernet ok" || { echo "Virtual bridged ethernet not ok"; exit 1; }
		echo "Virtual ethernet bridge IP address stored as $vbripadrss";;
	*)
		echo "Additional interface device $netw also detected. " 
		;;
esac
done




# create cert directory and passwords
mkdir /root/ldapca
cd /root/ldapca
echo "redhat" > capassword
echo "redhat" > password
head -c 100 /dev/urandom >> noise.txt


#This section creates the CA cert for self-signing the LDAP server cert and LDAP client cert
#I dont know why you cant do this in the /etc/openldap directory? Havent tried it.
#Basic steps are creating the database, the key pair, signing cert, creating the server cert, creating the client
#cert and exporting both to the certificate database
#I specify rsa security here, even though it is the default and has some vulnerabilities
#elliptical curve i think is the recommended, but I just wanted to get a lab working

#create the database
certutil -d /root/ldapca -N -f /root/ldapca/capassword

#create the signing key pair
certutil -d /root/ldapca -G -z noise.txt /root/ldapca/capassword

#create the CA cert
certutil -d /root/ldapca -S -k rsa -n "CA-certificate" -s "cn=LDAP_CA,dc=example,dc=com" -x -t "PCT,," -m 1000 -z /root/ldapca/noise.txt -f /root/ldapca/capassword 

#create the LDAP server cert 
certutil -d /root/ldapca -S -k rsa -n "OpenLDAP-Server" -s "cn=instructor.example.com" -c "CA-certificate" -t "u,u,u" -m 1001 -z /root/ldapca/noise.txt -f /root/ldapca/capassword

#create the cert for authentication
certutil -d /root/ldapca -S -k rsa -n "Auth-Client" -s "cn=auth,dc=example,dc=com" -c "CA-certificate" -t "u,u,u" -m 1002 -z /root/ldapca/noise.txt -f /root/ldapca/capassword

#Export the CA cert
certutil -d /root/ldapca/ -L -n "CA-certificate" -a > /root/ldapca/cacert.pem

#Export the LDAP server certificate and key
pk12util -d /root/ldapca/ -o ldapserver.p12 -n "OpenLDAP-Server" -k /root/ldapca/capassword -w /root/ldapca/password

#Export the Client Cert and key
pk12util -d /root/ldapca/ -o authclient.p12 -n "Auth-Client" -k /root/ldapca/capassword -w /root/ldapca/password

#Begin clean up of old data and LDAP setup
#Run on both machines if installing a separate client

rm -f /etc/openldap/certs/*

#Copy the lsapserver.p12 and cacert.pem files to certs directory for ldap
#if configuring a separate client, the password and authclient files will need to be scp'd
#to the client

cp /root/ldapca/ldapserver.p12 /etc/openldap/certs/.
cp /root/ldapca/cacert.pem /etc/openldap/certs/.
cp /root/ldapca/password /etc/openldap/certs/.
cp /root/ldapca/authclient.p12 /etc/openldap/certs/.

#Make new database with passowrd then add the server key
#I beleive if you are splitting this between separate host and clients #
#the first certutil command should be run on both machines
#pk12util will need to import the ldapserver.p12 on the server host and
#pk12util will need to import the authclient.p12 on the client

certutil -N -d /etc/openldap/certs -f /etc/openldap/certs/password
pk12util -i /etc/openldap/certs/ldapserver.p12 -k /etc/openldap/certs/password -w /etc/openldap/certs/password -d /etc/openldap/certs
pk12util -i /etc/openldap/certs/authclient.p12 -k /etc/openldap/certs/password -w /etc/openldap/certs/password -d /etc/openldap/certs

#Update configuration files for ldap.conf sssd.conf

#ldap.conf - client side config
echo "URI ldap://instructor.example.com" >> /etc/openldap/ldap.conf
echo "BASE dc=example,dc=com" >> /etc/openldap/ldap.conf
echo "TLS_REQUIRE allow" >> /etc/openldap/ldap.conf
echo "TLS_CACERT /etc/openldap/certs/cacert.pem" >> /etc/openldap/ldap.conf
echo "TLS_CACERTDIR /etc/openldap/certs" >> /etc/openldap/ldap.conf
echo "TLS_Cert /etc/openldap/certs/authclient.p12" >> /etc/openldap/ldap.conf
echo "TLS_KEY /etc/openldap/certs/password" >> /etc/openldap/ldap.conf

#sssd.conf - client side config
authconfig \
--enablesssd \
--enablesssdauth \
--enablelocauthorize \
--enableldap \
--enableldapauth \
--ldapserver=ldap://instructor.example.com \
--enableldapstarttls \
--enableldaptls \
--ldapbasedn=dc=example,dc=com \
--enablerfc2307bis \
--enablecachecreds \
--update

echo "ldap_tls_cacertdir = /etc/openldap/certs" >> /etc/sssd/sssd.conf
echo "entry_cache_timeout = 600 " >> /etc/sssd/sssd.conf
echo "ldap_network_timeout = 3" >> /etc/sssd/sssd/conf


#Do I need to make changes to nscd.conf to stop caching?

#Make sure certs are readable and have ldap ownership
chown -R ldap:ldap /etc/openldap/certs
chmod 644 /etc/openldap/certs/*

#Mark the CA cert as trusted
certutil -d /etc/openldap/certs -M -n "CA-certificate" -t "CTu,u,u"


###install and configure ldap for a test lab on CentOS7
##users are ldapuser1 through ldapuser10
##user passwords are all Z0mgbee!


#set slappasswd to "redhat"

slappasswd -s redhat -n > /etc/openldap/passwd

#copy sample config

cp /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG

#check to see if slaptest is ok then change ownership to ldap user - enable - start slapd

slaptest

if [ $? -eq 1 ] 
then
	chown -R ldap:ldap /var/lib/ldap
	systemctl enable slapd
	systemctl start slapd
	netstat -lt | grep ldap
else
	echo "slapd enable failed"
	systemctl status slapd
	exit 1
fi

#configure

# cd /etc/openldap/schema
ldapadd -Y EXTERNAL -H ldapi:/// -D "cn=config" -f cosine.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -D "cn=config" -f nis.ldif

#copy changes.ldif and base.ldif to correct directory if it is created or exit if not

[ -f /changes.ldif ] && cp /changes.ldif /etc/openldap/changes.ldif || { echo "Dude you need an ldif"; exit 1; }

[ -f /etc/openldap/changes.ldif ] && { ldapmodify -Y EXTERNAL -H ldapi:/// -f /etc/openldap/changes.ldif; } || { echo "failed to modify changes.ldif"; exit 1; }


[ -f /base.ldif ] && cp /base.ldif /etc/openldap/base.ldif || { echo "Dude you need an ldif"; exit 1; }


[ -f /etc/openldap/base.ldif ] && { ldapadd -x -w redhat -D cn=Manager,dc=example,dc=com -f /etc/openldap/base.ldif; } || { echo "failed to add base.ldif"; exit 1; }

#create users for testing

mkdir /home/guests

ldappwd='Z0mgbee!'

for u in {1..10}
do
	useradd -d /home/guests/ldapuser$u -p $ldappwd ldapuser$u
done

#migrate user accounts

cd /usr/share/migrationtools

[ -f /usr/share/migrationtools/migrate_common.ph ] && { sed -i 's/"padl.com"/"example.com"/' /usr/share/migrationtools/migrate_common.ph; } && { sed -i 's/"dc=padl,dc=com"/"dc=example,dc=com"/' /usr/share/migrationtools/migrate_common.ph; }

#create users in the directory service

grep ":10[0-9][0-9]" /etc/passwd > passwd
./migrate_passwd.pl passwd users.ldif
ldapadd -x -w redhat -D cn=Manager,dc=example,dc=com -f users.ldif
 
grep ":10[0-9][0-9]" /etc/group > group
./migrate_group.pl group groups.ldif
ldapadd -x -w redhat -D cn=Manager,dc=example,dc=com -f groups.ldif

#setup firewall

firewall-cmd --permanent --add-service=ldap
firewall-cmd --permanent --add-service=ldaps
firewall-cmd --reload

#enable logging

echo "local4.* /var/log/ldap.log" >> /etc/rsyslog.conf
systemctl restart rsyslog


echo "COMPLETE"
		
