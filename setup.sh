#!/bin/bash
GO_VERSION=$(go version 2>/dev/null | grep -oP 'go1\.22\.0')
if [ -z "$GO_VERSION" ]; then
    echo "Go is not installed or not version 1.22.0. Installing Go 1.22.0..."
    wget https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
    rm go1.22.0.linux-amd64.tar.gz
    if ! grep -q 'export GOPATH=' ~/.profile; then
        echo "export GOPATH=$HOME/go" >> ~/.profile
    fi
    if ! grep -q 'export PATH=.*$GOPATH/bin' ~/.profile; then
        echo "export PATH=$PATH:$GOPATH/bin" >> ~/.profile
    fi
    if ! grep -q 'export PATH=.*:/usr/local/go/bin' ~/.profile; then
        echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.profile
    fi
    source ~/.profile
else
    echo "Go version 1.22.0 is already installed."
fi
if ! grep -q 'export BABYLOND_KEYRING_BACKEND=file' ~/.profile; then
    echo "export BABYLOND_KEYRING_BACKEND=file" >> ~/.profile
    source ~/.profile
fi

sudo apt -qy install curl git jq lz4 build-essential unzip
rm -rf babylon
rm -rf $HOME/.babylond
git clone https://github.com/babylonchain/babylon.git
cd babylon
git checkout v0.8.3
make build

mkdir -p ~/.babylond/cosmovisor/genesis/bin
mkdir -p ~/.babylond/cosmovisor/upgrades

mv build/babylond $HOME/.babylond/cosmovisor/genesis/bin/
rm -rf build

sudo ln -s $HOME/.babylond/cosmovisor/genesis $HOME/.babylond/cosmovisor/current -f
sudo ln -s $HOME/.babylond/cosmovisor/current/bin/babylond /usr/local/bin/babylond -f

# Init Babylond
babylond version
read -p "Enter validator key name: " VALIDATOR_KEY_NAME
if [ -z "$VALIDATOR_KEY_NAME" ]; then
    echo "Error: No validator key name provided."
    exit 1
fi
read -p "Do you want to recover wallet? [y/N]: " RECOVER
if [[ "$RECOVER" =~ ^[Yy](es)?$ ]]; then
    babylond keys add $VALIDATOR_KEY_NAME --recover
else
    babylond keys add $VALIDATOR_KEY_NAME
fi
babylond keys list
babylond init $VALIDATOR_KEY_NAME --chain-id bbn-test-3

# Replace genesis.json
wget https://github.com/babylonchain/networks/raw/main/bbn-test-3/genesis.tar.bz2
tar -xjf genesis.tar.bz2 && rm genesis.tar.bz2
mv genesis.json $HOME/.babylond/config/genesis.json

# Babylond Config
sed -i -e "s|^seeds *=.*|seeds = \"49b4685f16670e784a0fe78f37cd37d56c7aff0e@3.14.89.82:26656,9cb1974618ddd541c9a4f4562b842b96ffaf1446@3.16.63.237:26656\"|" $HOME/.babylond/config/config.toml
sed -i 's/minimum-gas-prices = "0stake"/minimum-gas-prices = "0.00001ubbn"/' $HOME/.babylond/config/app.toml
sed -i -e "s|^network *=.*|network = \"signet\"|" $HOME/.babylond/config/app.toml
sed -i \
  -e 's|^pruning *=.*|pruning = "custom"|' \
  -e 's|^pruning-keep-recent *=.*|pruning-keep-recent = "100"|' \
  -e 's|^pruning-keep-every *=.*|pruning-keep-every = "0"|' \
  -e 's|^pruning-interval *=.*|pruning-interval = "10"|' \
  $HOME/.babylond/config/app.toml

# Helper tools
cd "$(dirname "$0")"
rm -rf babylon check_balance.sh create_validator.sh unjail_validator.sh check_validator.sh start_babylon.sh check_log.sh
echo "babylond q bank balances \$(babylond keys show $VALIDATOR_KEY_NAME -a)" > check_balance.sh && chmod +x check_balance.sh
tee create_validator.sh > /dev/null <<EOF
#!/bin/bash
babylond tx staking create-validator \
  --amount=1000000ubbn \
  --pubkey=\$(babylond tendermint show-validator) \
  --from=$VALIDATOR_KEY_NAME \
  --moniker="$VALIDATOR_KEY_NAME" \
  --chain-id="bbn-test-3" \
  --commission-rate="0.05" \
  --commission-max-rate="0.20" \
  --commission-max-change-rate="0.01" \
  --min-self-delegation="1" \
  --fees="200ubbn" \
  --gas-adjustment="1.4" \
  --gas=auto \
  --gas-prices="0.00001ubbn" \
  -y
EOF
chmod +x create_validator.sh
tee unjail_validator.sh > /dev/null <<EOF
#!/bin/bash
babylond tx slashing unjail \
 --from=$VALIDATOR_KEY_NAME \
 --chain-id="bbn-test-3" \
 --gas=auto \
 --fees="200ubbn"
EOF
chmod +x unjail_validator.sh
tee check_validator.sh > /dev/null <<EOF
#!/bin/bash
babylond query tendermint-validator-set | grep "\$(babylond tendermint show-address)"
EOF
chmod +x check_validator.sh
cat <<EOF > /etc/logrotate.d/babylond
$HOME/babylon/*.out {
    size 10M
    hourly
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
sudo systemctl enable babylond
sudo systemctl restart babylond
EOF
chmod +x start_babylon.sh
tee check_log.sh > /dev/null <<EOF
#!/bin/bash
journalctl -u babylond -f
EOF
chmod +x check_log.sh

if ! command -v cosmovisor &> /dev/null; then
    wget https://github.com/cosmos/cosmos-sdk/releases/download/cosmovisor%2Fv1.5.0/cosmovisor-v1.5.0-linux-amd64.tar.gz
    tar -xvzf cosmovisor-v1.5.0-linux-amd64.tar.gz
    rm cosmovisor-v1.5.0-linux-amd64.tar.gz
    sudo cp cosmovisor /usr/local/bin
fi
sudo tee /etc/systemd/system/babylond.service > /dev/null <<EOF
[Unit]
Description=Babylon daemon
After=network-online.target

[Service]
User=$USER
ExecStart=$(which cosmovisor) run start --x-crisis-skip-assert-invariants
Restart=always
RestartSec=3
LimitNOFILE=infinity

Environment="DAEMON_NAME=babylond"
Environment="DAEMON_HOME=${HOME}/.babylond"
Environment="DAEMON_RESTART_AFTER_UPGRADE=true"
Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
read -p "Do you want to enable the babylond service? (y/N): " ENABLE_SERVICE
if [[ "$ENABLE_SERVICE" =~ ^[Yy](es)?$ ]]; then
    sudo systemctl enable babylond.service
else
    echo "Skipping enabling babylond service."
fi