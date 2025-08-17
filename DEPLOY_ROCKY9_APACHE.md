# SequenceServer デプロイ手順（Rocky Linux 9 + Apache、サブパス /seqserv）

本手順は Rocky Linux 9 上で Apache と連携し、SequenceServer をサブディレクトリ `/seqserv` で公開する手順です。構成は Apache のリバースプロキシ（mod_proxy）でバックエンドの Rack アプリへ転送します。

- 公開URL: `http(s)://<host>/seqserv/`
- バックエンド: Rack (rackup) で `127.0.0.1:9292` を待受
- アプリ側: `config.ru` で `map '/seqserv'` 済み（本リポジトリはサブパス対応済み）
- BLAST DB ディレクトリ: `/data2/sequenceserver/db3`

---

## 1) 事前準備（root または sudo 権限）

パッケージ:

```
sudo dnf install -y httpd mod_ssl ncbi-blast+
sudo systemctl enable --now httpd
```

Ruby/Bundler（例: システムRubyを使用。環境に応じて rbenv 等でも可）:

```
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y git curl openssl-devel readline-devel zlib-devel libffi-devel libyaml-devel ruby ruby-devel rubygems
sudo gem install bundler -v 2.5.17
```

SELinux/Firewall（後段で再掲）:
- SELinux: `httpd_can_network_connect` を有効化
- Firewall: 80/443 を開放

### 1-2) Ruby 3.0.6 以上が必要な場合（rbenv の導入）

Rocky 9 の標準 Ruby が 3.0.4 の場合、以下のようなエラーになります:

Because every version of sequenceserver depends on Ruby >= 3.0.6 ... current Ruby version is = 3.0.4

この場合は apache ユーザのホーム配下に rbenv で新しい Ruby を導入してください。

```
sudo dnf install -y git gcc make bzip2 openssl-devel readline-devel zlib-devel libffi-devel libyaml-devel

# apache ユーザの HOME を指定して rbenv/ruby-build を導入
sudo -u apache env HOME=/usr/share/httpd bash -lc '
  set -e
  RBENV_ROOT="$HOME/.rbenv"
  if [ ! -d "$RBENV_ROOT" ]; then
    git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
    mkdir -p "$RBENV_ROOT/plugins"
    git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
  fi
  export PATH="$RBENV_ROOT/bin:$PATH"
  RUBY_VER=3.2.5
  rbenv install -s "$RUBY_VER"
  rbenv global "$RUBY_VER"
  gem install bundler -v 2.5.17 --no-document
  rbenv rehash
'
```

以降の bundle 実行は rbenv の shims を利用するため、`PATH` に `/usr/share/httpd/.rbenv/shims:/usr/share/httpd/.rbenv/bin` を含めます。

---

## 2) 実行ユーザは apache（新規ユーザは作成しない）

アプリ配置用ディレクトリ作成と権限付与:

```
sudo mkdir -p /data2/sequenceserver/sequenceserver-3kai
sudo chown -R apache:apache /data2/sequenceserver/sequenceserver-3kai
```

アプリ配置（このリポジトリを配置）:

```
sudo git clone <YOUR_GIT_REMOTE_URL> /data2/sequenceserver/sequenceserver-3kai || true
sudo chown -R apache:apache /data2/sequenceserver/sequenceserver-3kai
# 既に配置済みならスキップ
```

依存インストール（開発依存を省略、apache の HOME を明示）:

```
sudo -u apache env HOME=/usr/share/httpd PATH=/usr/share/httpd/.rbenv/shims:/usr/share/httpd/.rbenv/bin:$PATH bash -lc '
  cd /data2/sequenceserver/sequenceserver-3kai
  bundle _2.5.17_ install --without development
'
```

---

## 3) BLAST データベース（DB）設定

DB ディレクトリを作成し、権限付与（apache で読み書き可能に）:

```
sudo mkdir -p /data2/sequenceserver/db3
sudo chown -R apache:apache /data2/sequenceserver/db3
```

SequenceServer 設定（apache ユーザの HOME に作成。Rocky では通常 `/usr/share/httpd`）:

```
sudo -u apache env HOME=/usr/share/httpd bash -lc 'cat > ~/.sequenceserver.conf <<EOF
:database_dir: "/data2/sequenceserver/db3"
:num_threads: 4
EOF'
```

（初期DBがない場合は、画面の「Add BLAST Database」からFASTAをアップロードすると自動で `makeblastdb` が実行されます。）

---

## 4) systemd ユニット（バックエンド Rack サーバ）

ユニットファイル `/etc/systemd/system/seqserv.service` を作成（apache で起動、rbenv を利用）:

```
sudo tee /etc/systemd/system/seqserv.service >/dev/null <<'UNIT'
[Unit]
Description=SequenceServer (Rack) on 127.0.0.1:9292
After=network.target

[Service]
Type=simple
User=apache
Group=apache
WorkingDirectory=/data2/sequenceserver/sequenceserver-3kai
Environment=HOME=/usr/share/httpd
Environment=RBENV_ROOT=/usr/share/httpd/.rbenv
Environment=PATH=/usr/share/httpd/.rbenv/shims:/usr/share/httpd/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
# rbenv の bundle シムを使用
ExecStart=/usr/share/httpd/.rbenv/shims/bundle _2.5.17_ exec rackup --host 127.0.0.1 --port 9292 config.ru
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
```

反映と起動:

```
sudo systemctl daemon-reload
sudo systemctl enable --now seqserv
# 確認
curl -sS http://127.0.0.1:9292/seqserv/ | head
```

注: `/usr/bin/bundle` のパスは `which bundle` で実際のパスを確認し、必要に応じて差し替えてください。

---

## 5) SELinux と Firewall 設定

Apache からバックエンド（127.0.0.1:9292）への接続を許可:

```
sudo setsebool -P httpd_can_network_connect on
```

Firewall（80/443 を開放）:

```
sudo firewall-cmd --add-service=http --permanent
sudo firewall-cmd --add-service=https --permanent
sudo firewall-cmd --reload
```

---

## 6) Apache リバースプロキシ設定（/seqserv）

設定ファイル `/etc/httpd/conf.d/seqserv.conf` を作成:

```
sudo tee /etc/httpd/conf.d/seqserv.conf >/dev/null <<'CONF'
ProxyPreserveHost On
ProxyRequests Off

# /seqserv へのアクセスを許可
<Location /seqserv>
  Require all granted
</Location>

# アプリ側が config.ru で map '/seqserv' にマウント済みのため、転送先にも /seqserv を付与
ProxyPass        /seqserv http://127.0.0.1:9292/seqserv retry=0 timeout=60
ProxyPassReverse /seqserv http://127.0.0.1:9292/seqserv
CONF
```

Apache 再起動:

```
sudo systemctl restart httpd
```

---

## 7) 動作確認

ブラウザ:
- `http://<server>/seqserv/` でトップ画面

API:
- `curl -sS http://<server>/seqserv/searchdata.json | jq` で DB 一覧

機能:
- 「Add BLAST Database」でFASTAファイルをアップロード → 自動で `makeblastdb` 実施 → 画面がリロードされ反映
- 「Manage Databases」で Rename / Delete → 画面が自動リロードされ反映

---

## 8) よくあるハマりどころと対処

- 二重サブパス `/seqserv/seqserv/` になって 404 になる:
  - Apache 側の `ProxyPass /seqserv http://127.0.0.1:9292/seqserv` を確認。
  - アプリの redirect はアプリ相対パス（Sinatra が script_name を自動付与）で動作するよう修正済み。

- SELinux によるブロック（503/タイムアウト）:
  - `setsebool -P httpd_can_network_connect on` を適用。

- 権限/パス:
  - `/data2/sequenceserver/db3` が `apache` ユーザで読み書き可能か確認。
  - `~apache/.sequenceserver.conf`（= `/usr/share/httpd/.sequenceserver.conf`）の `:database_dir:` が `/data2/sequenceserver/db3` になっているか確認。

- bundler のパスが異なる:
  - `which bundle` でパスを確認し、systemd の ExecStart を調整。

---

## 9) 運用（service / log）

サービス:
```
sudo systemctl status seqserv
sudo systemctl restart seqserv
sudo journalctl -u seqserv -f
```

Apache ログ:
```
/var/log/httpd/access_log
/var/log/httpd/error_log
```

---

## 10) 参考（Passenger 構成にしたい場合の概要）

- EPEL から `mod_passenger` を導入し、Apache 直下に Rack アプリを配備。
- その場合はアプリをルートにマウント（`config.ru` の `map '/seqserv'` は削除）し、Apache 側で `<Location /seqserv>` と `PassengerAppRoot` などでサブURIに対応させる必要あり。
- 切り分けと可搬性の観点で、まずは本書のリバースプロキシ方式を推奨。

---

以上。
