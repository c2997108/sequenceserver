# DB登録機能付きSequenceServer - BLAST searching made easy!

SequenceServerはウェブブラウザで簡単にBlast検索ができるように設計されたツールですが、DBファイル（FASTAファイル）を登録するのは少し面倒でした。そこで、WEBブラウザからDBの登録・編集も可能にする機能を追加しました。また、Apacheなどと連携して設置しやすいように、サブフォルダー以下で(/seqserv/など)でも動作する機能を追加しています。

If you use SequenceServer, please cite our paper: 
[Sequenceserver: A modern graphical user interface for custom BLAST databases. Molecular Biology and Evolution (2019).](https://doi.org/10.1093/molbev/msz185)

## Installation

セットアップ@WSL Ubuntu

```
apt install build-essential
wget https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.16.0/ncbi-blast-2.16.0+-x64-linux.tar.gz
tar vxf ncbi-blast-2.16.0+-x64-linux.tar.gz

git clone https://github.com/c2997108/sequenceserver
cd sequenceserver
bash ./scripts/setup_sequenceserver_local.sh
cp spec/sequences/Nucleotide_TP53_COX41.fasta data/blastdb/
bin/seqserv-wrapper --host 0.0.0.0 --port 4567 --path-prefix /seqserv
#初回起動時に、blastの展開場所(例：/home/user/ncbi-blast-2.16.0+ )の指定と、DBの初期化を行う(初期化は全部Enterを押せばOK）。
```

セットアップ@Rocky Linux 9

```
git clone https://github.com/c2997108/sequenceserver
cd sequenceserver
bash ./scripts/setup_sequenceserver_local.sh
cp spec/sequences/Nucleotide_TP53_COX41.fasta data/blastdb/
bin/seqserv-wrapper --host 0.0.0.0 --port 4567 --path-prefix /seqserv

#サーバ起動時に自動実行するようにするには
#いったんroot（もしくは実際に実行させるユーザ）で実行しておく。blastへのパスなどはユーザごとに~/.sequenceserver.confに保存しているため。
sudo bin/seqserv-wrapper --host 0.0.0.0 --port 4567 --path-prefix /seqserv
#serviceファイルで、その他ユーザ名などを編集しておく
sed -i 's%/home/yoshitake.kazutoshi/work/seqserv2/sequenceserver%'"$PWD"'%' seqserv.service
sudo cp -i seqserv.service /usr/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now seqserv.service
```

無事に設置できていれば、下記のような画面が見えるはず。

<img width="1505" height="1603" alt="image" src="https://github.com/user-attachments/assets/dc2eac8d-508e-4fa3-84cd-3fc5dab100d4" />

## その他

Sequence Serverの使い方は本家サイトを見てください。

https://github.com/wurmlab/sequenceserver
