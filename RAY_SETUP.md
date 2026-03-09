# Ray分散処理サーバー構築手順

## 前提条件
- ✅ Consulサーバーが lyon002 と lyon004 で稼働中
- ✅ Tailscale経由で通信可能
- ✅ Dockerイメージ `lyon-raycluster:py311-gpu` がビルド済み

## 現在の状況確認

### Consulクラスターの状態確認
```bash
# 各ノードで実行
docker exec consul-server consul members
curl -sS http://127.0.0.1:8500/v1/status/leader
```

### Tailscale IPの確認
```bash
# lyon002で実行
docker exec consul-tailscale tailscale ip -4
# 出力例: 100.115.134.36

# lyon004で実行
docker exec consul-tailscale tailscale ip -4
# 出力例: 100.101.232.45
```

## Ray起動手順

### 方法1: 既存のTailscaleコンテナを利用（推奨）

既に `server-compose.yml` で起動している `consul-tailscale` コンテナのネットワークを共有します。

#### lyon002 (Head候補ノード)
```bash
cd ~/raycluster/consul
docker compose -f ray-only-head.yml up -d
```

#### lyon004 (Worker候補ノード)
```bash
cd ~/raycluster/consul
docker compose -f ray-only-worker.yml up -d
```

### 方法2: 独立したTailscaleコンテナで起動

各Rayコンテナに専用のTailscaleコンテナを付ける場合：

#### lyon002
```bash
cd ~/raycluster/consul
docker compose -f ray-head-tailscale.yml up -d
```

#### lyon004
```bash
cd ~/raycluster/consul
docker compose -f ray-worker-tailscale.yml up -d
```

## 起動確認

### コンテナ状態の確認
```bash
docker ps -a
```

期待される出力：
- `consul-server` - running
- `consul-tailscale` - running
- `ray-head-candidate` または `ray-worker-node` - running

### Rayログの確認
```bash
# Head候補ノードで
docker logs ray-head-candidate --tail 50

# Workerノードで
docker logs ray-worker-node --tail 50
```

### Consulサービス登録の確認
```bash
# ray-headサービスが登録されているか確認
curl -sS http://127.0.0.1:8500/v1/catalog/service/ray-head | jq
```

### Rayダッシュボードへのアクセス

Rayのheadが起動したら、ダッシュボードにアクセスできます：

```bash
# Headノードを確認
curl -sS http://127.0.0.1:8500/v1/catalog/service/ray-head | jq -r '.[0].ServiceAddress'
```

ブラウザで `http://<HeadのTailscale IP>:8265` にアクセス

### Jupyter Labへのアクセス

Head候補ノードでJupyterが起動している場合：

```bash
# ログ確認
cat ~/raycluster/workspace/logs/jupyter.log
```

ブラウザで `http://<HeadのTailscale IP>:8888` にアクセス

## トラブルシューティング

### Rayが起動しない場合

1. Consulへの接続確認
```bash
docker exec ray-head-candidate curl -sS http://127.0.0.1:8500/v1/status/leader
```

2. Tailscale接続確認
```bash
docker exec consul-tailscale tailscale status
```

3. Ray起動ログの詳細確認
```bash
docker logs ray-head-candidate --tail 100
docker logs ray-worker-node --tail 100
```

### リーダー選出が行われない場合

Consulのセッション情報を確認：
```bash
curl -sS http://127.0.0.1:8500/v1/session/list | jq
```

KVストアのリーダー情報を確認：
```bash
curl -sS http://127.0.0.1:8500/v1/kv/service/ray/leader | jq -r '.[0].Value' | base64 -d
```

### Workerがheadに接続できない場合

1. Headのサービス登録を確認
```bash
curl -sS http://127.0.0.1:8500/v1/catalog/service/ray-head | jq
```

2. Tailscale経由でHeadに到達できるか確認
```bash
# lyon004から実行
docker exec consul-tailscale ping -c 3 100.115.134.36
```

3. Rayポート（6379）が開いているか確認
```bash
# lyon004から実行
docker exec consul-tailscale nc -zv 100.115.134.36 6379
```

## 停止・再起動

### 個別停止
```bash
# Rayのみ停止
docker compose -f consul/ray-only-head.yml down
docker compose -f consul/ray-only-worker.yml down

# Consul + Tailscaleも停止
docker compose -f consul/server-compose.yml down
```

### 強制停止
```bash
docker rm -f ray-head-candidate ray-worker-node
```

### 再起動
```bash
# Consulが動いている状態で
cd ~/raycluster/consul
docker compose -f ray-only-head.yml up -d  # lyon002
docker compose -f ray-only-worker.yml up -d  # lyon004
```

## 次のステップ

1. Rayクラスターが正常に動作していることを確認
2. 簡単なRayジョブを実行してテスト
3. 必要に応じてノードを追加

### テストスクリプト例

```python
import ray

# Rayクラスターに接続（headノードで実行）
ray.init(address='auto')

# クラスター情報を表示
print(ray.cluster_resources())

# 簡単な分散タスク
@ray.remote
def hello():
    import socket
    return f"Hello from {socket.gethostname()}"

# 複数のタスクを実行
results = ray.get([hello.remote() for _ in range(4)])
print(results)
```
