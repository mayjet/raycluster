# raycluster

## VPN内のホスト名を使った起動ガイド

Ray の head/worker が Consul で検出したアドレスに到達できない場合、各 VM の VPN 内ホスト名を
`RAY_NODE_HOSTNAME` としてコンテナ起動時に渡してください。`getent hosts` で解決した IP を
Consul に登録し、worker が head に参加できるようにします。解決できない場合は自動検出へ
フォールバックします。`RAY_NODE_IP` で IP を直接指定することも可能です。実環境では
ホスト名の指定を推奨します。

### 1) Compose ファイルで固定指定する場合

`compose/ray-node-compose.yml` や `consul/head-compose.yml` / `consul/client-compose.yml` の
`environment` にある `RAY_NODE_HOSTNAME=SET_VPN_HOSTNAME` を、各 VM の VPN 内ホスト名に
置き換えてください。

### 2) 起動時にホスト名を入力する場合

VM ごとにホスト名が異なる場合は、起動時に環境変数で注入します。

```bash
RAY_NODE_HOSTNAME=lyon001.cloud.cs.priv.teu.ac.jp docker compose -f consul/head-compose.yml up -d
RAY_NODE_HOSTNAME=lyon010.cloud.cs.priv.teu.ac.jp docker compose -f consul/client-compose.yml up -d
```

`RAY_NODE_HOSTNAME` を指定しない場合は、コンテナ内から取得した IPv4 を使って
Consul に登録します。
