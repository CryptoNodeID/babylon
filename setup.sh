#!/bin/bash
DAEMON_NAME=babylond
DAEMON_HOME=$HOME/.${DAEMON_NAME}
INSTALLATION_DIR=$(dirname "$(realpath "$0")")
GOPATH=$HOME/go
cd ${INSTALLATION_DIR}
if ! grep -q 'export GOPATH=' ~/.profile; then
    echo "export GOPATH=$HOME/go" >> ~/.profile
    source ~/.profile
fi
if ! grep -q 'export PATH=.*:/usr/local/go/bin' ~/.profile; then
    echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.profile
    source ~/.profile
fi
if ! grep -q 'export PATH=.*$GOPATH/bin' ~/.profile; then
    echo "export PATH=$PATH:$GOPATH/bin" >> ~/.profile
    source ~/.profile
fi
GO_VERSION=$(go version 2>/dev/null | grep -oP 'go1\.22\.0')
if [ -z "$(echo "$GO_VERSION" | grep -E 'go1\.22\.0')" ]; then
    echo "Go is not installed or not version 1.22.0. Installing Go 1.22.0..."
    wget https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
    sudo rm -rf $(which go)
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
    rm go1.22.0.linux-amd64.tar.gz
else
    echo "Go version 1.22.0 is already installed."
fi
sudo apt -qy install curl git jq lz4 build-essential unzip
rm -rf babylon
rm -rf ${DAEMON_HOME}
if ! grep -q 'export BABYLOND_KEYRING_BACKEND=file' ~/.profile; then
    echo "export BABYLOND_KEYRING_BACKEND=file" >> ~/.profile
    source ~/.profile
fi
git clone https://github.com/babylonchain/babylon.git
cd babylon
git checkout v0.8.3
make build

mkdir -p ${DAEMON_HOME}/cosmovisor/genesis/bin
mkdir -p ${DAEMON_HOME}/cosmovisor/upgrades

mv build/${DAEMON_NAME} ${DAEMON_HOME}/cosmovisor/genesis/bin/
rm -rf build

sudo ln -s ${DAEMON_HOME}/cosmovisor/genesis ${DAEMON_HOME}/cosmovisor/current -f
sudo ln -s ${DAEMON_HOME}/cosmovisor/current/bin/${DAEMON_NAME} /usr/local/bin/${DAEMON_NAME} -f

# Init Babylond
${DAEMON_NAME} version
read -p "Enter validator key name: " VALIDATOR_KEY_NAME
if [ -z "$VALIDATOR_KEY_NAME" ]; then
    echo "Error: No validator key name provided."
    exit 1
fi
read -p "Do you want to recover wallet? [y/N]: " RECOVER
if [[ "$RECOVER" =~ ^[Yy](es)?$ ]]; then
    ${DAEMON_NAME} keys add $VALIDATOR_KEY_NAME --recover
else
    ${DAEMON_NAME} keys add $VALIDATOR_KEY_NAME
fi
${DAEMON_NAME} keys list
${DAEMON_NAME} init $VALIDATOR_KEY_NAME --chain-id bbn-test-3

# Replace genesis.json
wget https://github.com/babylonchain/networks/raw/main/bbn-test-3/genesis.tar.bz2
tar -xjf genesis.tar.bz2 && rm genesis.tar.bz2
mv genesis.json ${DAEMON_NAME}/config/genesis.json

# Babylond Config
sed -i -e "s|^seeds *=.*|seeds = \"49b4685f16670e784a0fe78f37cd37d56c7aff0e@3.14.89.82:26656,9cb1974618ddd541c9a4f4562b842b96ffaf1446@3.16.63.237:26656,ade4d8bc8cbe014af6ebdf3cb7b1e9ad36f412c0@testnet-seeds.polkachu.com:20656\"|" ${DAEMON_HOME}/config/config.toml
sed -i 's/minimum-gas-prices = "0ubbn"/minimum-gas-prices = "0.00001ubbn"/' ${DAEMON_HOME}/config/app.toml
sed -i -e "s|^network *=.*|network = \"signet\"|" ${DAEMON_HOME}/config/app.toml
sed -i \
  -e 's|^pruning *=.*|pruning = "custom"|' \
  -e 's|^pruning-keep-recent *=.*|pruning-keep-recent = "100"|' \
  -e 's|^pruning-keep-every *=.*|pruning-keep-every = "0"|' \
  -e 's|^pruning-interval *=.*|pruning-interval = "10"|' \
  ${DAEMON_HOME}/config/app.toml

# Helper tools
cd ${INSTALLATION_DIR}
read -p "Do you want to use custom port number prefix (y/N)? " use_custom_port
if [[ "$use_custom_port" =~ ^[Yy](es)?$ ]]; then
    read -p "Enter port number prefix (max 2 digits, not exceeding 50): " port_prefix
    while [[ "$port_prefix" =~ [^0-9] || ${#port_prefix} -gt 2 || $port_prefix -gt 50 ]]; do
        read -p "Invalid input, enter port number prefix (max 2 digits, not exceeding 50): " port_prefix
    done
    ${DAEMON_NAME} config node tcp://localhost:${port_prefix}657
    sed -i.bak -e "s%:1317%:${port_prefix}317%g; s%:8080%:${port_prefix}080%g; s%:9090%:${port_prefix}090%g; s%:9091%:${port_prefix}091%g; s%:8545%:${port_prefix}545%g; s%:8546%:${port_prefix}546%g; s%:6065%:${port_prefix}065%g" ${DAEMON_HOME}/config/app.toml
    sed -i.bak -e "s%:26658%:${port_prefix}658%g; s%:26657%:${port_prefix}657%g; s%:6060%:${port_prefix}060%g; s%:26656%:${port_prefix}656%g; s%:26660%:${port_prefix}660%g" ${DAEMON_HOME}/config/config.toml
fi
rm -rf babylon check_balance.sh create_validator.sh unjail_validator.sh check_validator.sh start_babylon.sh check_log.sh list_keys.sh
echo "${DAEMON_NAME} keys list" > list_keys.sh && chmod +x list_keys.sh
if [[ "$use_custom_port" =~ ^[Yy](es)?$ ]]; then
    echo "${DAEMON_NAME} q bank balances --node=tcp://localhost:${port_prefix}657 \$(${DAEMON_NAME} keys show $VALIDATOR_KEY_NAME -a)" > check_balance.sh && chmod +x check_balance.sh
else
    echo "${DAEMON_NAME} q bank balances \$(${DAEMON_NAME} keys show $VALIDATOR_KEY_NAME -a)" > check_balance.sh && chmod +x check_balance.sh
fi
tee validator.json > /dev/null <<EOF
{
        "pubkey": [VALIDATOR_PUBKEY],
        "amount": "90000ubbn",
        "moniker": "$VALIDATOR_KEY_NAME",
        "website": "$VALIDATOR_KEY_NAME",
        "security": "$VALIDATOR_KEY_NAME",
        "details": "$VALIDATOR_KEY_NAME",
        "commission-rate": "0.05",
        "commission-max-rate": "0.2",
        "commission-max-change-rate": "0.01",
        "min-self-delegation": "1"
}
EOF
sed -i "s/[VALIDATOR_PUBKEY]/$(${DAEMON_NAME} tendermint show-validator)/g" validator.json
tee create_validator.sh > /dev/null <<EOF
#!/bin/bash
if [[ "$use_custom_port" =~ ^[Yy](es)?$ ]]; then
    ${DAEMON_NAME} tx checkpointing create-validator ./validator.json \
        --chain-id="bbn-test-3" \
        --gas="auto" \
        --gas-adjustment="1.5" \
        --gas-prices="0.025ubbn" \
        --from=$VALIDATOR_KEY_NAME \
        --node="tcp://localhost:${port_prefix}657"
else
    ${DAEMON_NAME} tx checkpointing create-validator ./validator.json \
        --chain-id="bbn-test-3" \
        --gas="auto" \
        --gas-adjustment="1.5" \
        --gas-prices="0.025ubbn" \
        --from=$VALIDATOR_KEY_NAME
fi
EOF

chmod +x create_validator.sh
tee unjail_validator.sh > /dev/null <<EOF
#!/bin/bash
${DAEMON_NAME} tx slashing unjail \
 --from=$VALIDATOR_KEY_NAME \
 --chain-id="bbn-test-3" \
 --gas=auto \
 --fees="200ubbn"
EOF
chmod +x unjail_validator.sh
tee check_validator.sh > /dev/null <<EOF
#!/bin/bash
${DAEMON_NAME} query tendermint-validator-set | grep "\$(${DAEMON_NAME} tendermint show-address)"
EOF
chmod +x check_validator.sh
cat <<EOF > /etc/logrotate.d/${DAEMON_NAME}
$HOME/babylon/*.out {
    size 10M
    rotate 5
    copytruncate
    missingok
    compress
    compresscmd /bin/gzip
}
EOF
tee start_babylon.sh > /dev/null <<EOF
#!/bin/bash
sudo systemctl daemon-reload
sudo systemctl enable ${DAEMON_NAME}
sudo systemctl restart ${DAEMON_NAME}
EOF
chmod +x start_babylon.sh
tee check_log.sh > /dev/null <<EOF
#!/bin/bash
journalctl -u ${DAEMON_NAME} -f
EOF
chmod +x check_log.sh

if ! command -v cosmovisor > /dev/null 2>&1 || ! which cosmovisor &> /dev/null; then
    wget https://github.com/cosmos/cosmos-sdk/releases/download/cosmovisor%2Fv1.5.0/cosmovisor-v1.5.0-linux-amd64.tar.gz
    tar -xvzf cosmovisor-v1.5.0-linux-amd64.tar.gz
    rm cosmovisor-v1.5.0-linux-amd64.tar.gz
    sudo cp cosmovisor /usr/local/bin
fi
sudo tee /etc/systemd/system/${DAEMON_NAME}.service > /dev/null <<EOF
[Unit]
Description=Babylon daemon
After=network-online.target

[Service]
User=$USER
ExecStart=$(which cosmovisor) run start
Restart=always
RestartSec=3
LimitNOFILE=infinity

Environment="DAEMON_NAME=${DAEMON_NAME}"
Environment="DAEMON_HOME=${DAEMON_HOME}"
Environment="DAEMON_RESTART_AFTER_UPGRADE=true"
Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"

[Install]
WantedBy=multi-user.target
EOF
if ! grep -q 'export DAEMON_NAME=' $HOME/.profile; then
    echo "export DAEMON_NAME=${DAEMON_NAME}" >> $HOME/.profile
fi
if ! grep -q 'export DAEMON_HOME=' $HOME/.profile; then
    echo "export DAEMON_HOME=${DAEMON_HOME}" >> $HOME/.profile
fi
if ! grep -q 'export DAEMON_RESTART_AFTER_UPGRADE=' $HOME/.profile; then
    echo "export DAEMON_RESTART_AFTER_UPGRADE=true" >> $HOME/.profile
fi
if ! grep -q 'export DAEMON_ALLOW_DOWNLOAD_BINARIES=' $HOME/.profile; then
    echo "export DAEMON_ALLOW_DOWNLOAD_BINARIES=false" >> $HOME/.profile
fi
source $HOME/.profile

sudo systemctl daemon-reload
read -p "Do you want to enable the ${DAEMON_NAME} service? (y/N): " ENABLE_SERVICE
if [[ "$ENABLE_SERVICE" =~ ^[Yy](es)?$ ]]; then
    sudo systemctl enable ${DAEMON_NAME}.service
else
    echo "Skipping enabling ${DAEMON_NAME} service."
fi