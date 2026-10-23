# Server Setup Script

This script automates the initial setup and installation of SSH config for fresh VM installation.

## Prerequisites

- A fresh server with Ubuntu 24.04 installation.
- Access to the terminal as su user.

## Installation (One Script)

Run this single command to download and execute the script:

```bash
wget -O - https://raw.githubusercontent.com/emleonid/ls-server-init/dev/init.sh | bash
```

## How to Use

If you prefer a step-by-step flow, follow the steps below to download and execute the script.

### Step 1: Download the Script

Use the `wget` command to download the script from this repository.

```bash
wget https://raw.githubusercontent.com/emleonid/ls-server-init/dev/init.sh
```

### Step 2: Make the Script Executable

After downloading the script, give it executable permissions.

```bash
chmod +x init.sh
```

### Step 3: Run the Script

Run the script using the following command:

```bash
./init.sh
```
