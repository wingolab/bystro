#!/usr/bin/env bash

echo -e "\n\nInstalling Ubuntu/Debian (apt-get) dependencies\n"

sudo apt update
# Installs gcc, and more; may be too much
sudo apt install -y build-essential

sudo apt install -y openssl libssl-dev
# Not strictly necessary, useful however for much of what we do
sudo apt install -y git-all
# pigz for Bystro, used to speed up decompression primarily

sudo apt install -y pigz
sudo apt install -y unzip
sudo apt install -y wget
# For tests involving querying ucsc directly
sudo apt install -y libmysqlclient-dev libmysqld-dev

# for perlbrew, in case you want to install a different perl version
#https://www.digitalocean.com/community/tutorials/how-to-install-perlbrew-and-manage-multiple-versions-of-perl-5-on-centos-7
# centos 7 doesn't include bzip2
sudo apt install -y bzip2 
sudo apt install -y patch

sudo apt install -y cpan

sudo apt install -y nodejs
sudo npm install -g pm2