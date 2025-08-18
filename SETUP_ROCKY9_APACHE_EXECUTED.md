# SequenceServer セットアップ記録（Rocky Linux 9 + Apache、apacheユーザ、実行結果ベース）

これは実際に本環境で構築・検証して通った手順を整理したものです。
- 公開URL: `http://<host>/seqserv/`
- バックエンド: Rack (WEBrick) `127.0.0.1:9292`
- 実行ユーザ: `apache`
- BLAST DB ディレクトリ: `/data2/sequenceserver/db3`
- 必要BLAST+バージョン: `2.16.0+` 以上

本手順はシステムRuby (3.0.7) を用い、rbenvなしで構築しています。rbenvを使う場合は `DEPLOY_ROCKY9_APACHE.md` も参照してください。

---

## 1) 必要パッケージの導入とApache起動

```bash
sudo dnf -y groupinstall "Development Tools"
sudo dnf -y install \
  httpd mod_ssl git curl \
  openssl-devel readline-devel zlib-devel libffi-devel libyaml-devel \
  ruby ruby-devel rubygems

sudo systemctl enable --now httpd
sudo systemctl is-active httpd   # ACTIVE が返ること
```

---

## 2) アプリ配置（apacheユーザ所有）

```bash
sudo mkdir -p /data2/sequenceserver
sudo git clone --depth 1 https://github.com/c2997108/sequenceserver.git \
  /data2/sequenceserver/sequenceserver-3kai
sudo chown -R apache:apache /data2/sequenceserver
```

---

## 3) Ruby依存のインストール（apacheユーザでBundle）

Bundlerを指定バージョンで導入し、開発依存を除いてインストールします。

```bash
sudo gem install bundler -v 2.5.17 --no-document

sudo -u apache env HOME=/usr/share/httpd bash -lc '
  set -e
  cd /data2/sequenceserver/sequenceserver-3kai
  bundle _2.5.17_ config set --local without "development"
  bundle _2.5.17_ config set --local path "vendor/bundle"
  bundle _2.5.17_ install
'
```

---

## 4) BLAST+ の導入（NCBI公式バイナリ 2.16.0+）

Rocky9/EPELで `ncbi-blast+` が見つからない場合があるため、NCBIのtar.gzを利用しました。

```bash
VER=2.16.0
URL="https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/${VER}/ncbi-blast-${VER}+-x64-linux.tar.gz"

sudo mkdir -p /opt
cd /opt
sudo curl -fSL -o ncbi-blast-${VER}.tar.gz "$URL"
sudo tar -xzf ncbi-blast-${VER}.tar.gz
sudo rm -f ncbi-blast-${VER}.tar.gz

# 主要バイナリへシンボリックリンク
for b in blastn blastp blastx tblastn tblastx makeblastdb blastdbcmd; do
  sudo ln -sf "/opt/ncbi-blast-${VER}+/bin/$b" /usr/local/bin/$b
done

blastdbcmd -version   # 2.16.0+ が表示されること
```

---

## 5) SequenceServer 設定ファイルとDBディレクトリ

`apache` のHOMEを `/usr/share/httpd` として扱い、設定ファイルを配置します。

```bash
sudo mkdir -p /data2/sequenceserver/db3
sudo chown -R apache:apache /data2/sequenceserver/db3

# ~/.sequenceserver.conf をapacheのHOMEに作成
sudo bash -lc 'cat > /usr/share/httpd/.sequenceserver.conf <<EOF
:database_dir: "/data2/sequenceserver/db3"
:num_threads: 14
:bin: "/suikou/tool9/ncbi-blast-2.16.0+/bin"
EOF'
sudo chown apache:apache /usr/share/httpd/.sequenceserver.conf
```

重要: 初回起動には1つ以上のBLASTデータベースが必要です。空だと起動に失敗します。

サンプルDB作成（FASTA→makeblastdb）:
```bash
sudo -u apache bash -lc 'cat > /data2/sequenceserver/db3/sample.fna <<FA
>seq1
ACGTACGTACGT
>seq2
ACGTACGTACGA
FA'

sudo -u apache env PATH=/usr/local/bin:/usr/bin bash -lc '
  cd /data2/sequenceserver/db3 && \
  makeblastdb -in sample.fna -dbtype nucl -parse_seqids -hash_index -title sample
'
```

---

## 6) systemd ユニット作成と起動

システムRuby + Bundlerで `rackup` を起動するユニットです。

`/etc/systemd/system/seqserv.service`:
```ini
[Unit]
Description=SequenceServer (Rack) on 127.0.0.1:9292
After=network.target

[Service]
Type=simple
User=apache
Group=apache
WorkingDirectory=/data2/sequenceserver/sequenceserver-3kai
Environment=HOME=/usr/share/httpd
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/usr/bin/bundle _2.5.17_ exec rackup --host 0.0.0.0 --port 9292 config.ru
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

反映・起動・確認:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now seqserv
sudo systemctl status --no-pager seqserv
curl -sS http://127.0.0.1:9292/seqserv/ | head
```

---

## 7) Apache リバースプロキシ設定（/seqserv）

モジュール確認:
```bash
sudo httpd -M | grep -E 'proxy(_http)?_module'
```

設定 `/etc/httpd/conf.d/seqserv.conf`:
```apache
ProxyPreserveHost On
ProxyRequests Off

<Location /seqserv>
  Require all granted
</Location>

RequestHeader set X-Forwarded-Proto "https"
RequestHeader set X-Forwarded-Port  "443"
ProxyPass        /seqserv http://127.0.0.1:9292/seqserv retry=0 timeout=60
ProxyPassReverse /seqserv http://127.0.0.1:9292/seqserv
```

Apache再起動と確認:
```bash
sudo systemctl restart httpd
curl -sS http://127.0.0.1/seqserv/ | head
```

---

## 8) SELinux / Firewall（必要に応じて）

SELinuxがEnforcingの場合、Apache→127.0.0.1:9292 を許可:
```bash
sudo setsebool -P httpd_can_network_connect on
```

Firewall（外部に80/443を開ける場合）:
```bash
sudo firewall-cmd --add-service=http --permanent
sudo firewall-cmd --add-service=https --permanent
sudo firewall-cmd --reload
```

---

## 9) 動作確認

- バックエンド: `curl -sS http://127.0.0.1:9292/seqserv/ | head`
- Apache経由: `curl -sS http://<host>/seqserv/ | head`
- DB一覧: `curl -sS http://<host>/seqserv/searchdata.json`

---

## 10) トラブルシュートの要点

- BLAST+バージョン不一致: `2.16.0+` 以上でないと起動失敗。`blastdbcmd -version` を確認し、必要ならNCBIのtarを入れ直す。
- 初回DBなし: `NO_BLAST_DATABASE_FOUND` で失敗。`makeblastdb` でDBを1つ以上作ってから起動。
- SELinuxでのブロック: `setsebool -P httpd_can_network_connect on`
- 権限: `/data2/sequenceserver/db3` が `apache:apache`、`~apache/.sequenceserver.conf` が正しいか。
- Bundlerパス: `which bundle` で `/usr/bin/bundle` を確認。rbenv使用時はシムパスに合わせる。

---

以上で、Apache配下 `/seqserv` でSequenceServerが稼働します。HTTPS化や認証追加が必要であれば別途ご相談ください。

