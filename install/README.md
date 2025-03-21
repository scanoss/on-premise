# SCANOSS On-Premise 

# Introduction

This document aims to guide users through the process of installing SCANOSS for on-premise environments.

This repository contains all necessary scripts for installing the SCANOSS Knowledge Base (SCANOSS KB), SCANOSS applications (engine, ldb, api and scanoss-encoder), dependencies, knowledge base updates and verifying a correct installation of every component.

# Hardware requisites

The following is recommended for running the SCANOSS Applications and SCANOSS KB:

- Operating systems supported: Debian 11/12 and CentOS

|     | Minimum                   | Recommended               |
|-----|---------------------------|---------------------------|
| CPU | 8 Core x64 - 3.5 Ghz      | 32 Core x64 - 3.6 Ghz     |
| RAM | 32GB                      | 128GB                     |
| HDD | 18TB SSD (NVMe preferred) | 22TB SSD (NVMe preferred) | 

# Contents of this repository

- [install-scanoss.sh](./install-scanoss.sh): bash script for installing SCANOSS (SFTP user setup creation, dependencies installation and application download/install)
- [kb.sh](./kb.sh): bash script for installing the SCANOSS KB
- [test.sh](./test.sh): bash script for verifying the correct installation of SCANOSS and the SCANOSS KB
- [resources](/resources): directory containing files for testing the installation of SCANOSS and the SCANOSS KB
- [config.sh](./config.sh): configuration file
- [kb-update.sh](../update): directory containing the knowledge base update guide and script

# Step-by-step

## Preparing the environment 

After receiving the email from our Sales team containing this repository's contents as well as the credentials to access our SFTP server, you will have everything needed to begin installing SCANOSS.

Make sure the scripts have execution permissions, if not add them with the following command:

```
chmod -R +x <scripts-folder>/*.sh
```

Another thing to keep in my mind is that this script needs to be run as root, either using ```sudo``` or directly as the root user.

## Installing SCANOSS with install-scanoss.sh

The first script you'll need to run is ``install-scanoss.sh``, this script will take care of setting up your SFTP credentials, installing system/application dependencies and downloading/installing SCANOSS applications.

To run the command type:

```
./install-scanoss.sh
```

You will be prompted with the following menu:

```
Starting scanoss installation script...

SCANOSS Installation Menu
------------------------
1) Install everything
2) Install Dependencies
3) Setup SFTP Credentials
4) Download Application
5) Install Application
6) Quit

Enter your choice [1-6]:
```

The first option ```Install everything``` includes all other options, that means that this option will install system dependencies (based on the host machine OS), setup your SFTP user credentials (for pulling the application packages from our SFTP server, and in ```kb.sh``` pulling the SCANOSS KB), download application packages and installing SCANOSS applications.

In some cases, users may prefer to manually trigger each step and maybe skipping one (e.g. users who may want to download packages from one computer, and installing them in another). So if you are in this situation, the correct workflow for manual trigger of options would be:

1. Install Dependencies: this will automatically download all required system dependencies, based on your OS
2. Setup SFTP Credentials: this option will prompt the user for their credentials (SFTP user and password)
3. Download Application: this option will let you choose between download application packages from our SFTP server, or downloading it manually (instructions for setting up the correct directory structure and permissions included on the script)
4. Install Application: this option will prompt the user with another menu with different options such as ```Install all applications and application dependencies```, ```Install application dependencies``` and options for installing each SCANOSS application separately.

> **_Note:_**  During the script, you will also be prompted for setting up installation paths and so on. We recommend using the default values for most options, this will make it easier for debugging if needed.

### API service startup

By default, the script doesn't start the API service, in order to start it run the following command:

```
systemctl start scanoss-go-api.service
```

To check the status of the service run

```
systemctl status scanoss-go-api.service
```

And to stop the service run:

```
systemctl stop scanoss-go-api.service
```

> **_Note:_** You may need to run this commands with ```sudo <command>```, depending on your environment configuration.

### API Configuration

In case you want to modify the configuration of the API service, the configuration file will be located in ```/opt/scanoss/tmp/scripts/app-config-prod.json``` (defined by the APP_DIR variable in ```config.sh```).

Inside the configuration file, you will see multiple options such as app information, logging, telemetry, networking, TLS encryption and filtering. All the available configuration options are already present in the file, though some may be empty.

To restart the service with the new options you added/modified, run the ```install-scanoss.sh``` choose option 5) Install Application and then option 5) API, and the service will update with the new configuration.

## Installing the SCANOSS Knowledge Base

When ```installation-script.sh``` is done, you can proceed to run the SCANOSS KB installation script ```kb.sh```.

To run the command type:

```
./kb.sh
```

After executing the script, you will be prompted with the following menu

```
SCANOSS KB Installation Menu
----------------------------
1) Install SCANOSS KB
2) Quit
Enter your choice [1-2]:
```

If you choose the first option, the SCANOSS KB installation will start.

For users wanting to install the SCANOSS KB on the background, we recommend using ```tmux``` and following this procedure:

1. Install ```tmux```: ```sudo apt update && sudo apt install tmux``` for Debian or ```sudo yum install epel-release && sudo yum install tmux``` for CentOS.
2. Verify installation using ```tmux --version```
3. Create a tmux session and attach to it using ```tmux new-session -s mysession```
4. Run the ```kb.sh``` script inside of the tmux session, and begin installing the SCANOSS KB
5. After triggering the installation you can dettach from the session by pressing ```Ctrl+B``` and then ```d```, and attach again by using ```tmux attach -t mysession```

## Verifying installation

After running ```install.sh``` and ```kb.sh```, you will have installed everything you need to run SCANOSS.

The only thing left to do is verifying everything is functioning properly, and for that we will be using the ```test.sh```  script.

Before running this script, make sure the ```/resources``` folder has read permissions, if not add them with:

```
chmod -R +r /resources
```

To run the command type:

```
./test.sh
```

After executing the script, you will be prompted with the following menu

```
Starting verification script for SCANOSS...

Select options from the menu to verify different aspects of your environment
----------------------------------------------------------------------------
1) Verify scanning feature
2) Check API service status
3) Check API service metrics
4) Quit
```

The output to look for would be the following:

- For the ```Verify scanning feature``` option, you will get a file called ```scan_results.json```. Make sure the file is showing a file match for the test file located on the ```/resources``` folder.
- For the ```Check API service status``` you should get ```{"alive"}: true``` as a response.
- And, for the ```Check API service metrics``` you should get the number of requests, performed scans and so on.

After verifying every part of SCANOSS is working, the installation process would be finished

# Support

If you encounter any issues with the scripts or have any questions, feel free to get in touch with us through the channels provided by the sales team.
