#!/bin/bash

# Define URLs for action scripts
URL_VM_INIT="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/vm_init.sh"
URL_POSTGRESQL="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/install_postgresql.sh"
URL_RABBITMQ="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/install_rabbitmq.sh"
URL_DOCKER="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/install_docker_compose.sh"
URL_NGINX="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/install_nginx.sh"
URL_NGINX_SSL="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/configure_nginx_ssl.sh"
URL_FAIL2BAN="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/configure_fail2ban.sh"
URL_SCRIPTS="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/additional_scripts.sh"

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Array of actions for the menu
OPTIONS=(
    "1. Server VM Initialization"
    "2. Install PostgreSQL server (VM-based)"
    "3. Install RabbitMQ server (VM-based)"
    "4. Install Docker compose setup"
    "5. Install nginx server"
    "6. Configure nginx SSL updates"
    "7. Configure fail2ban setup"
    "8. Additional scripts"
    "Exit"
)

# Function to download, execute, and remove the script
execute_script() {
    local url=$1
    local script_name=$(basename "$url")
    
    echo -e "${GREEN}Downloading script...${NC}"
    wget -q "$url" -O "$script_name"

    # Check if download was successful and file is non-empty
    if [ -f "$script_name" ] && [ -s "$script_name" ]; then
        echo -e "${GREEN}Downloaded ${script_name} successfully.${NC}"

        # Execute the script and check if it runs successfully
        echo -e "${GREEN}Executing ${script_name}...${NC}"
        bash "$script_name"
        
        if [ $? -eq 0 ]; then
            # Execution was successful
            echo -e "${GREEN}${script_name} executed successfully.${NC}"
            rm -f "$script_name"
            echo -e "${GREEN}${script_name} removed from disk.${NC}\n"
        else
            # Execution failed, ask user if they want to delete the file
            echo -e "${RED}An error occurred while executing ${script_name}.${NC}"
            read -p "Do you want to delete ${script_name}? (y/n): " delete_choice
            if [[ "$delete_choice" =~ ^[Yy]$ ]]; then
                rm -f "$script_name"
                echo -e "${GREEN}${script_name} has been deleted.${NC}"
            else
                echo -e "${YELLOW}${script_name} has been kept on disk.${NC}"
            fi
        fi
    else
        # Download failed or file is empty
        echo -e "${RED}Failed to download ${script_name} or the file is empty. Please check the URL or your connection.${NC}"
        rm -f "$script_name"  # Remove any empty or incomplete file
    fi
    read -p "Press [Enter] to return to menu."
}

# Function to display the menu
show_menu() {
    tput civis   # Hide the cursor
    trap "tput cnorm; exit" SIGINT SIGTERM  # Restore cursor on exit

    local choice=0

    while true; do
        clear
        echo -e "${GREEN}Legiosoft Script Menu...${NC}"
        echo "Use UP and DOWN arrows to navigate and ENTER to select an option."

        # Loop to display options
        for i in "${!OPTIONS[@]}"; do
            if [ "$i" -eq "$choice" ]; then
                echo -e "> ${GREEN}${OPTIONS[$i]}${NC}"
            else
                echo "  ${OPTIONS[$i]}"
            fi
        done

        # Read user input for navigation
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A') ((choice--));;  # UP arrow
                '[B') ((choice++));;  # DOWN arrow
            esac
        elif [[ $key == "" ]]; then
            case $choice in
                0) execute_script "$URL_VM_INIT" ;;
                1) execute_script "$URL_POSTGRESQL" ;;
                2) execute_script "$URL_RABBITMQ" ;;
                3) execute_script "$URL_DOCKER" ;;
                4) execute_script "$URL_NGINX" ;;
                5) execute_script "$URL_NGINX_SSL" ;;
                6) execute_script "$URL_FAIL2BAN" ;;
                7) execute_script "$URL_SCRIPTS" ;;
                8) echo "Exiting..."; tput cnorm; exit 0 ;;
            esac
        fi

        # Wrap the selection around
        ((choice < 0)) && choice=$((${#OPTIONS[@]} - 1))
        ((choice >= ${#OPTIONS[@]})) && choice=0
    done

    tput cnorm  # Restore the cursor
}

# Run the menu
show_menu
