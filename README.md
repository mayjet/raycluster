# raycluster


## まず使うコマンド（管理者権限なし運用向け）

`~/raycluster` 直下に、既存構成を壊さずに使える運用スクリプトを追加しています。

- `./consul_cluster.sh`: Consulサーバーの起動/停止/確認
- `./ray_cluster.sh`: Ray head/worker の起動/停止/確認

### Consul（既存の tailscale + consul 構成を維持）

```bash
cd ~/raycluster
./consul_cluster.sh up --bootstrap-expect 3 --retry-join "lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp lyon040.cloud.cs.priv.teu.ac.jp"
./consul_cluster.sh status
```

`--tailscale-ip` を省略した場合は、`consul-tailscale` コンテナから自動取得します。

### Ray

```bash
cd ~/raycluster

# Head候補を起動（既存の consul-tailscale を利用）
./ray_cluster.sh up head --tailscale 1 --container-name ray-head-lyon002 --node-hostname lyon002.cloud.cs.priv.teu.ac.jp

# Workerを起動（既存の consul-tailscale を利用）
./ray_cluster.sh up worker --tailscale 1 --container-name ray-worker-lyon004 --node-hostname lyon004.cloud.cs.priv.teu.ac.jp

./ray_cluster.sh status
```

Head起動時は、`~/.ssh/authorized_keys` が存在すれば自動でコンテナへコピーされます。

## VPN内のホスト名を使った起動ガイド

Ray の head/worker が Consul で検出したアドレスに到達できない場合、各 VM の VPN 内ホスト名を
`RAY_NODE_HOSTNAME` としてコンテナ起動時に渡してください。`getent hosts` で解決した IP を
Consul に登録し、worker が head に参加できるようにします。解決できない場合は自動検出へ
フォールバックします。`RAY_NODE_IP` で IP を直接指定することも可能です。実環境では
ホスト名の指定を推奨します。

## 実行手順（詳細）

以下は 2 台構成（`lyon002` を head + Consul サーバー、`lyon004` を worker + Consul サーバー）
の例です。Consul サーバーを置かないノードは `consul/client-compose.yml` を使います。

### 0) 前提

- 各ノードで Docker / Docker Compose が利用できること
- GPU ノードの場合は NVIDIA ドライバが有効であること
- それぞれの VPN 内ホスト名が `getent hosts` で解決できること

### 1) イメージをビルド（全ノード）

```bash
cd ~/raycluster
docker build -f docker/Dockerfile.gpu -t lyon-raycluster:py311-gpu .
```

### 2) Consul サーバーを起動（サーバーになるノードのみ）

Consul サーバーを置くノードでのみ実行します。

```bash
cd ~/raycluster/consul
docker compose -f server-compose.yml up -d
```

Consul サーバーが 1 台だけの場合は、`bootstrap-expect=1` にする必要があります。

```bash
cd ~/raycluster/consul
CONSUL_BOOTSTRAP_EXPECT=1 docker compose -f server-compose.yml up -d
```

### 2-B) Consul サーバーを 2 台構成にする場合（lyon002 + lyon004）

2 台で運用する場合は、`bootstrap-expect=2` のままにして、**両ノードが起動してはじめて
leader が選出**されます。2 台目を起動するまで leader は空になります。

Consul サーバーは `-bind` に **コンテナ内の有効なIP** が必要です。
このリポジトリでは **起動時にコンテナ内で自動検出**するため、
`CONSUL_BIND` は **advertise 用（ホスト側IP）**として使います。

1) `lyon002` で起動
```bash
cd ~/raycluster/consul
CONSUL_BIND=$(getent hosts lyon002.cloud.cs.priv.teu.ac.jp | awk '{print $1}' | head -n1)
CONSUL_BOOTSTRAP_EXPECT=2 CONSUL_BIND=$CONSUL_BIND \
  docker compose -f server-compose.yml up -d
```

2) `lyon004` でも同様に起動
```bash
cd ~/raycluster/consul
CONSUL_BIND=$(getent hosts lyon004.cloud.cs.priv.teu.ac.jp | awk '{print $1}' | head -n1)
CONSUL_BOOTSTRAP_EXPECT=2 CONSUL_BIND=$CONSUL_BIND \
  docker compose -f server-compose.yml up -d
```

3) 互いに join させる（1回だけ）
```bash
# lyon002 から lyon004 へ
docker exec -it consul-server consul join lyon004.cloud.cs.priv.teu.ac.jp

# lyon004 から lyon002 へ
docker exec -it consul-server consul join lyon002.cloud.cs.priv.teu.ac.jp
```

4) leader が返っていることを確認
```bash
curl -sS http://127.0.0.1:8500/v1/status/leader
```
2 台とも空でなければ OK です。

### 2-C) `-bind` を自動設定する（毎回の手入力をなくす）

`scripts/gen_consul_env.sh` で **ホスト名付きの .env** を生成し、
`--env-file` で読み込ませます（共有ホームでも上書きしないため）。
以降は `docker compose --env-file <env> -f server-compose.yml up -d` だけで起動できます。

初回のみ実行権限を付与してください。
```bash
chmod +x scripts/gen_consul_env.sh
```

lyon002:
```bash
cd ~/raycluster
CONSUL_BIND_HOSTNAME=lyon002.cloud.cs.priv.teu.ac.jp \
CONSUL_BOOTSTRAP_EXPECT=2 \
CONSUL_RETRY_JOIN="lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp" \
  ./scripts/gen_consul_env.sh
cd consul
docker compose --env-file .env.lyon002 -f server-compose.yml up -d
```

lyon004:
```bash
cd ~/raycluster
CONSUL_BIND_HOSTNAME=lyon004.cloud.cs.priv.teu.ac.jp \
CONSUL_BOOTSTRAP_EXPECT=2 \
CONSUL_RETRY_JOIN="lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp" \
  ./scripts/gen_consul_env.sh
cd consul
docker compose --env-file .env.lyon004 -f server-compose.yml up -d
```

`CONSUL_BIND_HOSTNAME` で取得した IP がローカルに存在しない場合は失敗するため、
確実にしたい場合はインターフェース名で指定できます。

```bash
CONSUL_BIND_IFACE=ens3 \
CONSUL_BOOTSTRAP_EXPECT=2 \
CONSUL_RETRY_JOIN="lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp" \
  ./scripts/gen_consul_env.sh
cd consul
docker compose --env-file .env.$(hostname -s) -f server-compose.yml up -d
```

### 3) Ray head を起動（head ノード）

Consul サーバーのノードで head を起動します。

```bash
cd ~/raycluster/consul
RAY_NODE_HOSTNAME=lyon002.cloud.cs.priv.teu.ac.jp \
  docker compose -f head-compose.yml up -d
```

### 4) Ray worker を起動（worker ノード）

#### 4-A) Consul サーバーを同居させる場合

Consul サーバーを既に起動しているノードでは `worker-compose.yml` を使います。

```bash
cd ~/raycluster/consul
RAY_NODE_HOSTNAME=lyon004.cloud.cs.priv.teu.ac.jp \
  docker compose -f worker-compose.yml up -d
```

#### 4-B) Consul サーバーを置かない場合

Consul クライアントを起動して worker を参加させます。

```bash
cd ~/raycluster/consul
RAY_NODE_HOSTNAME=lyon004.cloud.cs.priv.teu.ac.jp \
  docker compose -f client-compose.yml up -d
```

### 5) 起動確認

```bash
docker ps -a
```

head ノードの Ray が起動したら、Ray ダッシュボードが `http://<headのIP>:8265` で見えるはずです。

### 6) 停止・やり直し

```bash
cd ~/raycluster/consul
docker compose -f head-compose.yml down
docker compose -f worker-compose.yml down
docker compose -f client-compose.yml down
docker compose -f server-compose.yml down
```

強制的にやり直す場合は、対象コンテナを削除してから再起動します。

```bash
docker rm -f ray-head-candidate ray-worker-node consul-server consul-client || true
```

### 1) Compose ファイルで固定指定する場合

`compose/ray-node-compose.yml` や `consul/head-compose.yml` / `consul/client-compose.yml` の
`environment` にある `RAY_NODE_HOSTNAME=SET_VPN_HOSTNAME` を、各 VM の VPN 内ホスト名に
置き換えてください。

### 2) 起動時にホスト名を入力する場合

VM ごとにホスト名が異なる場合は、起動時に環境変数で注入します。

```bash
RAY_NODE_HOSTNAME=___.ac.jp docker compose -f consul/head-compose.yml up -d
RAY_NODE_HOSTNAME=___.ac.jp docker compose -f consul/client-compose.yml up -d
```

`RAY_NODE_HOSTNAME` を指定しない場合は、コンテナ内から取得した IPv4 を使って
Consul に登録します。

### 3) Consul サーバー / クライアントの使い分け

- Consul サーバーにするノードでは `consul/server-compose.yml` だけ起動します。
- そのノードで Ray を動かす場合は `consul/worker-compose.yml` を使い、`consul/client-compose.yml` は起動しません。
- Consul サーバーではないノードは `consul/client-compose.yml` を使います。

`server-compose.yml` と `client-compose.yml` を同一ホストで同時に起動すると、
同じポートを掴みに行くため `consul-client` が再起動ループになります。

### 4) 再起動ループ時の確認ポイント

`docker logs` に `curl: option -sSF: is badly used here` が出る場合、
コンテナ内の `curl` 設定ファイルが原因で起動スクリプトが失敗しています。
このリポジトリでは `curl -q` で設定を無視するよう修正済みなので、
イメージを再ビルドしてから再起動してください。

```bash
docker build -f docker/Dockerfile.gpu -t lyon-raycluster:py311-gpu .
docker compose -f consul/head-compose.yml up -d
docker compose -f consul/client-compose.yml up -d
```
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
