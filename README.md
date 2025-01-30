# SCANOSS On-Premise 

# Introduction

This document aims to guide users through the process of installing SCANOSS for on-premise environments.

This repository contains all necessary scripts for installing the SCANOSS Knowledge Base (SCANOSS KB), SCANOSS applications (engine, ldb, api and scanoss-encoder) and dependencies.

# Hardware requisites

The following is recommended for running the SCANOSS Applications and SCANOSS KB:

- Operating systems supported: Debian 11/12 and CentOS

|     | Minimum                   | Recommended               |
|-----|---------------------------|---------------------------|
| CPU | 8 Core x64 - 3.5 Ghz      | 32 Core x64 - 3.6 Ghz     |
| RAM | 32GB                      | 128GB                     |
| HDD | 18TB SSD (NVMe preferred) | 22TB SSD (NVMe preferred) | 

# Contents of this repository

- install-script.sh: bash script for installing SCANOSS (SFTP user setup creation, dependencies installation and application download/install)
- kb.sh: bash script for installing the SCANOSS KB
- config.sh: configuration file

# Step-by-step

** Preparing the environment **

After receiving the email from our Sales team containing this repository's contents as well as the credentials to access our SFTP server, you will have everything needed to begin installing SCANOSS.

Make sure the scripts have execution permissions, if not add them with the following command:

```
  chmod -R +x <folder_containing_scripts>
```

Another thing to keep in my mind is that this script needs to be run as root, either using ```sudo``` or directly as the root user.

** Installing SCANOSS with install-script.sh **

The first script you'll need to run is ``install-script.sh``, this script will take care of setting up your SFTP credentials, installing system/application dependencies and downloading/installing SCANOSS applications.

To run the command type:

```
  ./install-script.sh
```

You will be prompted with the following menu:

```
Starting scanoss installation script...

SCANOSS Installation Menu
------------------------
1) Install SCANOSS Platform
2) Install Dependencies
3) Setup SFTP Credentials
4) Download Application
5) Install Application
6) Quit

Enter your choice [1-6]:
```

The first option ```Install SCANOSS Platform``` includes all other options, that means that this option will install system dependencies (based on the host machine OS), setup your SFTP user credentials (for pulling the application packages from our SFTP server, and in ```kb.sh``` pulling the SCANOSS KB), download application packages and installing SCANOSS applications.

In some cases, users may prefer to manually trigger each step and maybe skipping one (e.g. users who may want to download packages from one computer, and installing them in another). So if you are in this situation, the correct workflow for manual trigger of options would be:

1. Install Dependencies: this will automatically download all required system dependencies, based on your OS
2. Setup SFTP Credentials: this option will prompt the user for their credentials (SFTP user and password)
3. Download Application: this option will let you choose between download application packages from our SFTP server, or downloading it manually (instructions for setting up the correct directory structure and permissions included on the script)
4. Install Application: this option will prompt the user with another menu with different options such as ```Install all applications and application dependencies```, ```Install application dependencies``` and options for installing each SCANOSS application separately.

> **_Note:_**  During the script, you will also be prompted for setting up installation paths and so on. We recommend using the default values for most options, this will make it easier for debugging if needed.

** Installing the SCANOSS Knowledge Base **

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



