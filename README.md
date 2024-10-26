# Server Setup Script

This script automates the initial setup and installation of SSH config for fresh VM installation.

## Prerequisites

- A fresh Server with Ubuntu 24.04 installation.
- Access to the terminal as su user.

## How to Use

Follow the steps below to download and execute the script.

### Step 1: Download the Script

Use the `wget` command to download the script from this repository.

```bash
wget https://raw.githubusercontent.com/emleonid/ls-server-init/dev/init.sh
```

### Step 2: Make the Script Executable
After downloading the script, you need to give it executable permissions using the chmod command.

```bash
chmod +x init.sh
```

### Step 3: Run the Script
Now you can run the script using the following command:

```bash
./init.sh
```
