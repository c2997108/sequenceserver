# SequenceServer を別サーバの Apache 経由で公開する手順

バックエンド(SequenceServer)とフロント(別サーバのApache)を分離する構成の手順です。

- バックエンド: 本サーバの `rackup` で `0.0.0.0:9292` を待受
- フロント: 別サーバの Apache から `/seqserv` をリバースプロキシ

---

## 1) バックエンド側（このサーバ）

### 1-1) `seqserv.service` を 0.0.0.0 で待受に変更

`/etc/systemd/system/seqserv.service` の `ExecStart` オプションの `--host` を `127.0.0.1` → `0.0.0.0` に変更します。

```bash
sudo sed -i 's/--host 127\.0\.0\.1/--host 0.0.0.0/' /etc/systemd/system/seqserv.service
sudo systemctl daemon-reload
sudo systemctl restart seqserv
```

確認:
```bash
ss -ltn | grep ':9292'      # 0.0.0.0:9292 で LISTEN
curl -sS http://127.0.0.1:9292/seqserv/ | head
```

### 1-2) firewalld で 9292/tcp を開放（暫定）

```bash
sudo firewall-cmd --add-port=9292/tcp --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports | grep 9292
```

より安全にするには、Apacheサーバの送信元IPに限定します（推奨）。

```bash
APACHE_IP=<ApacheサーバのIPv4>
sudo firewall-cmd --permanent --remove-port=9292/tcp
sudo firewall-cmd --permanent \
  --add-rich-rule="rule family=ipv4 source address=${APACHE_IP}/32 port port=9292 protocol=tcp accept"
sudo firewall-cmd --reload
```

SELinuxはバックエンド→外部通信は行わないため特別なブール値は不要です（通常設定のままで可）。

---

## 2) フロント側（別サーバの Apache）

### 2-1) モジュール確認

```bash
sudo httpd -M | grep -E 'proxy(_http)?_module'
```

### 2-2) リバースプロキシ設定

`/etc/httpd/conf.d/seqserv.conf` を作成（`<BACKEND_IP>` はバックエンドサーバの到達可能アドレスに置換）。

```apache
ProxyPreserveHost On
ProxyRequests Off

<Location /seqserv>
  Require all granted
</Location>

ProxyPass        /seqserv http://<BACKEND_IP>:9292/seqserv retry=0 timeout=60
ProxyPassReverse /seqserv http://<BACKEND_IP>:9292/seqserv
```

SELinux（Enforcingのとき）:
```bash
sudo setsebool -P httpd_can_network_connect on
```

Apache再起動と確認:
```bash
sudo systemctl restart httpd
curl -sS http://<APACHE_HOST>/seqserv/ | head
```

---

## 3) 動作確認と補足

- バックエンドのDBディレクトリに最低1つのBLAST+ DBが必要（空だと起動失敗）。
- BLAST+ は `2.16.0+` 以上。`blastdbcmd -version` で確認。
- 既に `DEPLOY_ROCKY9_APACHE.md` での初期セットアップ（bundler、`.sequenceserver.conf`、DB作成、`seqserv.service` 等）が完了している前提です。

---

## 4) セキュリティのベストプラクティス

- 9292/tcp の公開は最小限のソースIPに限定（firewalldのrich rule、またはVPC/SGで制御）。
- インターネット越しの直接到達は避け、Apache側でTLSを終端。
- 必要に応じてApache側で基本認証やIP制限を追加。

