# Ray分散処理サーバー構築ガイド（Tailscale統合版）

## 構成概要

### アーキテクチャ

```
lyon002:
  ├─ consul-tailscale コンテナ (Tailscale IP: 100.115.134.36)
  │   └─ consul-server (Consulサーバー)
  └─ ray-tailscale コンテナ (Tailscale IP: 別のIP)
      └─ ray-head-candidate (Ray Head候補)

lyon004:
  ├─ consul-tailscale コンテナ (Tailscale IP: 100.101.232.45)
  │   └─ consul-server (Consulサーバー)
  └─ ray-tailscale コンテナ (Tailscale IP: 別のIP)
      └─ ray-head-candidate (Ray Head候補)
```

### 設計のポイント

1. **Consulクラスター**: 既に稼働中（lyon002 + lyon004）
2. **Rayクラスター**: 新規構築（lyon002 + lyon004 の両方がHead候補）
3. **Tailscale統合**: 各RayコンテナがTailscaleコンテナとネットワークを共有
4. **自動リーダー選出**: Consulが1つのノードをHeadに選出、もう1つはWorkerになる

## 前提条件

- ✅ Consulサーバーが lyon002 と lyon004 で稼働中
- ✅ Dockerイメージ `lyon-raycluster:py311-gpu` がビルド済み
- ✅ Tailscaleアカウントにログイン可能

## ステップ1: Compose設定ファイルの確認

既に作成済みの `consul/ray-head-tailscale.yml` を使用します。

### ファイル構造

```yaml
version: '3.8'

services:
  ray-head-candidate:
    image: lyon-raycluster:py311-gpu
    container_name: ray-head-candidate
    network_mode: "service:ray-tailscale"  # ← Tailscaleのネットワークを共有
    restart: unless-stopped
    depends_on:
      - ray-tailscale
    volumes:
      - ~/raycluster/workspace:/workspace
      - ~/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro  # SSH用
    environment:
      - HEAD_MODE=false  # 自動リーダー選出
      - CONSUL_HTTP_ADDR=http://100.115.134.36:8500  # ← ConsulのTailscale IP
      - JUPYTER=yes
      - RAY_memory_monitor_refresh_ms=2500
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]

  ray-tailscale:
    image: tailscale/tailscale:latest
    container_name: ray-tailscale
    hostname: ray-${HOSTNAME:-unknown}  # ← Consulと区別するため
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_ACCEPT_DNS=false
    volumes:
      - ./tailscale-state-ray-${HOSTNAME:-unknown}:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    restart: unless-stopped
    command: tailscaled

networks:
  default:
    external: true
    name: consul-net
```

### 重要な変更点

1. **hostname**: `ray-${HOSTNAME}` に変更（Consulと区別）
2. **container_name**: `ray-tailscale` に変更
3. **volumes**: `tailscale-state-ray-${HOSTNAME}` に変更（Consulと別の状態ディレクトリ）
4. **CONSUL_HTTP_ADDR**: ConsulのTailscale IPを指定

## ステップ2: Compose設定ファイルの修正

現在の `ray-head-tailscale.yml` を修正します。

### 修正が必要な箇所

```yaml
# 修正前
environment:
  - CONSUL_HTTP_ADDR=http://127.0.0.1:8500

# 修正後（lyon002の場合）
environment:
  - CONSUL_HTTP_ADDR=http://100.115.134.36:8500
```

**理由**: RayコンテナとConsulコンテナは別のTailscaleネットワークにいるため、`127.0.0.1` ではアクセスできません。

### lyon002用の設定

```bash
cd ~/raycluster/consul
cat > ray-head-tailscale-lyon002.yml <<'EOF'
version: '3.8'

services:
  ray-head-candidate:
    image: lyon-raycluster:py311-gpu
    container_name: ray-head-candidate
    network_mode: "service:ray-tailscale"
    restart: unless-stopped
    depends_on:
      - ray-tailscale
    volumes:
      - ~/raycluster/workspace:/workspace
      - ~/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro
    environment:
      - HEAD_MODE=false
      - CONSUL_HTTP_ADDR=http://100.115.134.36:8500
      - JUPYTER=yes
      - RAY_memory_monitor_refresh_ms=2500
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]

  ray-tailscale:
    image: tailscale/tailscale:latest
    container_name: ray-tailscale
    hostname: ray-lyon002
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_ACCEPT_DNS=false
    volumes:
      - ./tailscale-state-ray-lyon002:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    restart: unless-stopped
    command: tailscaled
EOF
```

### lyon004用の設定

```bash
cd ~/raycluster/consul
cat > ray-head-tailscale-lyon004.yml <<'EOF'
version: '3.8'

services:
  ray-head-candidate:
    image: lyon-raycluster:py311-gpu
    container_name: ray-head-candidate
    network_mode: "service:ray-tailscale"
    restart: unless-stopped
    depends_on:
      - ray-tailscale
    volumes:
      - ~/raycluster/workspace:/workspace
      - ~/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro
    environment:
      - HEAD_MODE=false
      - CONSUL_HTTP_ADDR=http://100.101.232.45:8500
      - JUPYTER=yes
      - RAY_memory_monitor_refresh_ms=2500
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]

  ray-tailscale:
    image: tailscale/tailscale:latest
    container_name: ray-tailscale
    hostname: ray-lyon004
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_ACCEPT_DNS=false
    volumes:
      - ./tailscale-state-ray-lyon004:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    restart: unless-stopped
    command: tailscaled
EOF
```

## ステップ3: Rayコンテナの起動

### lyon002で実行

```bash
cd ~/raycluster/consul

# Rayコンテナを起動
docker compose -f ray-head-tailscale-lyon002.yml up -d

# Tailscale認証リンクを取得
docker logs ray-tailscale 2>&1 | grep "https://login.tailscale.com"
```

**出力例:**
```
To authenticate, visit: https://login.tailscale.com/a/xxxxxxxxxxxx
```

ブラウザでこのリンクを開いて認証します。

### lyon004で実行

```bash
cd ~/raycluster/consul

# Rayコンテナを起動
docker compose -f ray-head-tailscale-lyon004.yml up -d

# Tailscale認証リンクを取得
docker logs ray-tailscale 2>&1 | grep "https://login.tailscale.com"
```

同様にブラウザで認証します。

## ステップ4: Tailscale IPの確認

### lyon002

```bash
docker exec ray-tailscale tailscale ip -4
```

**出力例:** `100.x.x.x`（新しいTailscale IP）

### lyon004

```bash
docker exec ray-tailscale tailscale ip -4
```

**出力例:** `100.y.y.y`（新しいTailscale IP）

## ステップ5: 起動確認

### コンテナ状態の確認

```bash
# 各ノードで実行
docker ps -a
```

**期待される出力:**
```
CONTAINER ID   IMAGE                        STATUS    NAMES
xxxxxxxxxxxx   lyon-raycluster:py311-gpu    Up        ray-head-candidate
xxxxxxxxxxxx   tailscale/tailscale:latest   Up        ray-tailscale
xxxxxxxxxxxx   consul:1.14                  Up        consul-server
xxxxxxxxxxxx   tailscale/tailscale:latest   Up        consul-tailscale
```

### Rayログの確認

```bash
# lyon002で実行
docker logs ray-head-candidate --tail 50
```

**成功パターン（Headになった場合）:**
```
Acquired leadership as lyon002
Starting Ray head...
Ray runtime started.
```

**成功パターン（Workerになった場合）:**
```
Joining head at 100.x.x.x
Ray runtime started.
```

### Consulサービス登録の確認

```bash
# どちらのノードでも実行可能
curl -sS http://100.115.134.36:8500/v1/catalog/service/ray-head | jq
```

**期待される出力:**
```json
[
  {
    "ServiceName": "ray-head",
    "ServiceAddress": "100.x.x.x",
    "ServicePort": 6379,
    "ServiceTags": ["ray", "head"]
  }
]
```

## ステップ6: アクセス確認

### Rayダッシュボード

```bash
# Headノードを確認
HEAD_IP=$(curl -sS http://100.115.134.36:8500/v1/catalog/service/ray-head | jq -r '.[0].ServiceAddress')
echo "Ray Dashboard: http://${HEAD_IP}:8265"
```

ブラウザでアクセスして、2つのノードが表示されることを確認。

### Jupyter Lab

```bash
echo "Jupyter Lab: http://${HEAD_IP}:8888"
```

### SSH接続

```bash
# lyon002のRayコンテナに接続
RAY_IP_002=$(docker exec ray-tailscale tailscale ip -4)
ssh root@${RAY_IP_002}

# lyon004のRayコンテナに接続
RAY_IP_004=$(docker exec ray-tailscale tailscale ip -4)
ssh root@${RAY_IP_004}
```

## ステップ7: 動作テスト

### Jupyter Labでテスト

Headノードの Jupyter Lab にアクセスして、以下のコードを実行：

```python
import ray
import socket

# Rayクラスターに接続
ray.init(address='auto')

# クラスター情報を表示
print("Cluster Resources:")
print(ray.cluster_resources())

# 分散タスクのテスト
@ray.remote
def hello():
    return f"Hello from {socket.gethostname()}"

# 複数のタスクを実行
results = ray.get([hello.remote() for _ in range(10)])
print("\nTask Results:")
for i, result in enumerate(results):
    print(f"Task {i}: {result}")
```

**期待される出力:**
```
Cluster Resources:
{'CPU': 16.0, 'GPU': 2.0, 'memory': ..., 'node:100.x.x.x': 1.0, 'node:100.y.y.y': 1.0}

Task Results:
Task 0: Hello from ray-lyon002
Task 1: Hello from ray-lyon004
Task 2: Hello from ray-lyon002
...
```

## トラブルシューティング

### 問題1: RayがConsulに接続できない

**症状:**
```
docker logs ray-head-candidate
curl: (7) Failed to connect to 127.0.0.1 port 8500
```

**原因:** `CONSUL_HTTP_ADDR` が間違っている

**解決策:**
```bash
# ConsulのTailscale IPを確認
docker exec consul-tailscale tailscale ip -4

# Compose設定を修正して再起動
docker compose -f ray-head-tailscale-lyon002.yml down
# CONSUL_HTTP_ADDR を正しいIPに修正
docker compose -f ray-head-tailscale-lyon002.yml up -d
```

### 問題2: Tailscale認証が完了しない

**症状:**
```
docker logs ray-tailscale
Waiting for authentication...
```

**解決策:**
```bash
# 認証リンクを再取得
docker logs ray-tailscale 2>&1 | grep "https://login.tailscale.com"

# ブラウザで認証
# 認証後、コンテナを再起動
docker restart ray-tailscale
docker restart ray-head-candidate
```

### 問題3: 両方のノードがWorkerになる

**症状:**
```
docker logs ray-head-candidate
Joining head at ...
```

**原因:** Consulのロックが取得できていない

**解決策:**
```bash
# Consulのセッション情報を確認
curl -sS http://100.115.134.36:8500/v1/session/list | jq

# KVストアをクリア
curl -X DELETE http://100.115.134.36:8500/v1/kv/service/ray/leader

# 両方のRayコンテナを再起動
docker restart ray-head-candidate
```

### 問題4: SSH接続できない

**症状:**
```
ssh root@100.x.x.x
Permission denied (publickey)
```

**解決策:**
```bash
# authorized_keysが正しくマウントされているか確認
docker exec ray-head-candidate ls -la /root/.ssh/

# マウントされていない場合、Compose設定を修正
# volumes:
#   - ~/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro

# 再起動
docker compose -f ray-head-tailscale-lyon002.yml down
docker compose -f ray-head-tailscale-lyon002.yml up -d
```

## 停止・再起動

### 個別停止

```bash
# lyon002
docker compose -f consul/ray-head-tailscale-lyon002.yml down

# lyon004
docker compose -f consul/ray-head-tailscale-lyon004.yml down
```

### 強制停止

```bash
docker rm -f ray-head-candidate ray-tailscale
```

### 再起動

```bash
# lyon002
docker compose -f consul/ray-head-tailscale-lyon002.yml up -d

# lyon004
docker compose -f consul/ray-head-tailscale-lyon004.yml up -d
```

## まとめ

この構成により：

✅ 各RayコンテナがTailscaleで独立したIPを持つ
✅ Consulクラスターに接続してリーダー選出
✅ 自動的に1つがHead、1つがWorkerになる
✅ Headが落ちたら自動的にフェイルオーバー
✅ SSH接続で開発作業が可能
✅ Jupyter Labでインタラクティブ開発

次のステップ：
- ノードを追加する場合は同じ手順で追加可能
- GPU利用の設定確認
- 本格的な分散処理タスクの実行
