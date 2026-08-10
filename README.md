# vivado-mac-cli

AMD Vivado 2026.1 を Apple Silicon Mac 上で **headless(CLI のみ)** で動かすツール。コマンド名は `vivado-mac`。

Docker / Lima / XQuartz は使わない。Apple 純正 **Virtualization.framework** を Swift から直接叩き、
Ubuntu 24.04 (ARM64) VM に **Rosetta 2** を注入して x86-64 Linux 版 Vivado をほぼネイティブ速度で実行する。

```
Mac (Apple Silicon)
└─ vivado-mac (Swift CLI, 依存ゼロ, ad-hoc署名のみ)
   └─ Virtualization.framework VM: Ubuntu 24.04 ARM64
      ├─ Rosetta 2 (VZLinuxRosettaDirectoryShare + binfmt_misc) ← x86-64 AOT変換
      ├─ Vivado 2026.1 (x86-64) … /opt/Xilinx (VMディスク内)
      └─ /work … Mac の ~/vivado-work を virtiofs 共有
```

## 必要なもの

- Apple Silicon Mac、macOS 13+(macOS 15+ 推奨: Rosetta 2 の AVX2 対応)
- Xcode Command Line Tools(`swift`)のみ。Homebrew も Docker も不要
- ディスク空き ~120 GB(Vivado standard 構成)
- AMD アカウント(インストーラのダウンロードとライセンス取得に必要)

## セットアップ

```bash
make build
sudo make install        # /usr/local/bin/vivado-mac
vivado-mac setup         # VM作成 + プロビジョニング(初回のみ、数分)
```

`setup` は Ubuntu cloud image の取得(SHA256検証)→ qcow2→raw 変換(内蔵コンバータ)→
cloud-init による VM 構築 → Rosetta で x86-64 バイナリが実際に実行できるかのスモークテストまで自動で行う。

次に [AMD のダウンロードページ](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools/2026-1.html)
から Linux 用 Web インストーラ(`FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_*_Lin64.bin`、要ログイン)を取得して:

```bash
vivado-mac install ~/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_0616_1700_Lin64.bin
```

AMD アカウントでのトークン認証(対話)→ エディション選択(ConfigGen)→ バッチインストールが走る。
ダウンロードは数十 GB、1〜3 時間。

## ライセンス(2026.1 の重要な変更)

2026.1 からライセンス必須(無償の **BASIC** tier あり: 7-series 全デバイス等、年次更新)。
ライセンスは **Ethernet MAC にノードロック**される。vivado-mac は VM の MAC アドレスを固定・永続化しているので:

1. `vivado-mac status` で VM MAC を確認
2. https://www.xilinx.com/getlicense で BASIC ライセンスを生成(その MAC を指定)
3. `~/vivado-work/Xilinx.lic` として保存(ゲスト側は `XILINXD_LICENSE_FILE=/work/Xilinx.lic` 設定済み)

## 使い方

```bash
vivado-mac vivado -version
vivado-mac vivado -mode batch -source build.tcl    # ~/vivado-work がカレント
vivado-mac vivado -mode tcl                        # 対話 Tcl
vivado-mac run make                                # ゲストで任意コマンド(複数引数 = argv)
vivado-mac run 'df -h / && free -h'                # 単一引数 = シェル文字列として解釈
vivado-mac shell                                   # ゲストにログイン
vivado-mac start / stop / status / doctor
vivado-mac destroy                                 # VM全削除(~/vivado-work は残す)
```

プロジェクトは `~/vivado-work`(ゲストの `/work`)に置く。Mac 側のエディタでそのまま編集できる。

## 検証済み(2026-08-10, M4 Mac / macOS 26.5)

Vivado 2026.1 の **synth → opt → place → route → write_bitstream フルフロー完走**を確認済み
(xc7a35t 用ビットストリーム生成、無償 BASIC ライセンス使用)。

## Rosetta 下の既知の注意点(このツールが自動対処するもの)

- **xsetup が「32bit 非対応」で即死** → ARM bash の `uname -m` が原因。`/opt/vivado-shim` の
  uname/arch シムで解決(install/wrapper/profile.d に組込済み)
- **インストーラの Java が子プロセスを spawn できない** → JDK 既定の vfork が Rosetta で壊れる。
  `JAVA_TOOL_OPTIONS=-Djdk.lang.Process.launchMechanism=FORK` で解決(profile.d 設定済み)
- **ダウンロード中の `NoRouteToHost`** → AMD の CDN が AAAA を返すが VZ NAT は IPv4 のみ。
  `-Djava.net.preferIPv4Stack=true` + ゲスト独立 DNS(1.1.1.1/8.8.8.8)で解決
- **`synth_design failed / stoi`(2026.1 新規)** → 新機能 FeatureStore が `/usr/bin/lscpu` を
  絶対パス実行して値を `std::stoi` する。ARM の lscpu は `Socket(s): -` 等を返すため例外。
  lscpu を dpkg-divert して x86 形式を返すシムに置換(実体は `lscpu.distrib`)
- **libncurses.so.5 不在** → AMD 同梱の Ubuntu/24 用 x86-64 ncurses5 をシンボリックリンク

## Rosetta 下の残る注意点(ユーザー側)

- **`launch_runs` は避ける**: 子プロセス spawn 経路が壊れやすい。in-process Tcl
  (`synth_design` → `opt_design` → `place_design` → `route_design` → `write_bitstream`)を使う
- Vivado が `realloc(): invalid pointer` で落ちたら(2026.1 では未再現):
  `export LD_PRELOAD=/opt/Xilinx/udev_stub_x86_64.so` を試す
- `xsdb` 等の他ツールは `vivado-mac shell` 内で `source /opt/Xilinx/*/Vivado/settings64.sh`
- USB JTAG 書き込みは非対応(headless スコープ外)。ビットストリームは `/work` に出るので、
  書き込みは openFPGALoader(Mac ネイティブ)等を利用
- Apple は Rosetta 2 の一般提供を macOS 27 まで保証(WWDC 2025)。macOS 28 以降は要注視

## 状態ファイル

すべて `~/.vivado-mac/` に置かれる(VMディスク `disk.img`、設定 `config.json`、ログ `console.log` /
`vmhost.log`、SSH鍵)。`vivado-mac destroy` で全削除。

## 参考

- [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) /
  [minorin22 fork](https://github.com/minorin22/vivado-on-silicon-mac) — Docker + VNC による GUI 版の先行実装
- UG973 (2026.1): 対応 OS は Ubuntu 22.04/24.04, RHEL 8/9/10 ほか
