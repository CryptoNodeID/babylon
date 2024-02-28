### Prerequisite :
#### Ensure 'tar' and 'unzip' already installed
    apt-get update -y && apt-get install tar unzip -y
### Steps
#### Download the release:
    wget https://github.com/CryptoNodeID/babylon/releases/download/0.8.3/v0.8.3.zip && unzip v0.8.3.zip -d babylon
#### run setup command : 
    cd babylon && chmod ug+x *.sh && ./setup.sh
#### follow the instruction and then run below command to start the node :
    ./start_babylon.sh && ./check_log.sh
