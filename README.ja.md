# vivado-mac-cli

AMD Vivado 2026.1 を Apple Silicon Mac 上で **headless(CLI)** で動かすツール。オプションで XQuartz 経由の GUI も使える。コマンド名は `vivado-mac`。[English README](README.md)

Docker / Lima は使わない。Apple 純正 **Virtualization.framework** を Swift から直接叩き、
Ubuntu 24.04 (ARM64) VM に **Rosetta 2** を注入して x86-64 Linux 版 Vivado をほぼネイティブ速度で実行する。

```
Mac (Apple Silicon)
├─ XQuartz(任意、Homebrew で導入)⇐ ssh -Y で Vivado GUI のウィンドウが Mac デスクトップに出る
└─ vivado-mac (Swift CLI, 依存ゼロ, ad-hoc署名のみ)
   └─ Virtualization.framework VM: Ubuntu 24.04 ARM64
      ├─ Rosetta 2 (VZLinuxRosettaDirectoryShare + binfmt_misc) ← x86-64 AOT変換
      ├─ Vivado 2026.1 (x86-64) … /opt/Xilinx (VMディスク内)
      └─ /work … Mac の ~/vivado-work を virtiofs 共有
```

## What's new here(新規性)

Apple Silicon で Vivado を動かす先行例([ichi4096](https://github.com/ichi4096/vivado-on-silicon-mac) の Docker+VNC、[filmil](https://github.com/filmil/vivado-docker) の Docker headless)はいずれも 2025.x まで。本プロジェクトの新規点は4つ:

1. **Vivado 2026.1 を Apple Silicon で動かした初の公開事例**。2026.1 新機能 FeatureStore が `/usr/bin/lscpu` の出力を `std::stoi` でパースするため、ARM 系環境では合成完了後に `stoi` エラーで死ぬ。`__cxa_throw` フックで根本原因を特定し lscpu シムで解決 — 他に文書化された例なし
2. **コンテナ不使用**。amd64 userland の Docker ではなく「ARM ネイティブ Ubuntu + multiarch x86-64 ライブラリ」構成。Vivado 以外はすべてネイティブ動作、Docker Desktop(企業ライセンス問題)不要、依存は Xcode CLT のみ
3. **このハイブリッド構成固有の対策群**(Docker では発生しないため未文書だった): ARM bash 用 uname シム、JDK vfork→FORK、IPv4-only NAT × AAAA CDN 対策
4. **2026.1 のライセンス必須化に対応した設計**(VM MAC の固定・永続化)

限界も明記: Rosetta 2 の保証は macOS 27 まで、速度はネイティブ比 7〜8割、無償 tier は 7-series まで。

## 必要なもの

- Apple Silicon Mac、macOS 13+(macOS 15+ 推奨: Rosetta 2 の AVX2 対応)
- Xcode Command Line Tools(`swift`)のみ。Docker 不要。GUI を使う場合のみ Homebrew(XQuartz 導入用)
- ディスク空き ~120 GB(7-series 構成。Zynq UltraScale+ MPSoC 等を追加すると各 10〜20 GB 増)。VM ディスクは**スパースファイル**で、Mac 側はゲストが実際に書いた分しか消費しない(VM 内の空き容量は Mac の容量を食わない)。実使用量は `vivado-mac status` に表示
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
vivado-mac install    # ~/Downloads のインストーラを自動発見
```

AMD アカウントでのトークン認証(対話)→ エディション選択(ConfigGen)→ バッチインストールが走る。
ダウンロードは数十 GB、1〜3 時間。

## ライセンス(2026.1 の重要な変更)

2026.1 からライセンス必須(無償の **BASIC** tier あり、年次更新)。BASIC の対象は [AMD の tier 表](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html)によれば 7-series 全デバイス、Spartan/Artix UltraScale+、Kintex UltraScale+ KU3P/KU5P、**Zynq UltraScale+ MPSoC ZU1〜ZU7**(CG/EG)。ZU2EG ボードは対象内。`vivado-mac install` の ConfigGen で該当デバイスファミリにチェックを入れること(後から削除は不可)。ILA/デバッグコアと IBERT は BASIC 対象外。
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

### GUI(任意、XQuartz 経由)

```bash
vivado-mac gui-setup          # 初回のみ: Homebrew で XQuartz、ゲストに xauth/フォント、表示テスト
vivado-mac gui                # Vivado GUI。各ウィンドウが Mac 上の XQuartz ネイティブウィンドウになる
vivado-mac gui proj/top.xpr   # プロジェクトを開く(~/vivado-work からの相対パス)
vivado-mac run --x11 CMD      # 任意の X11 プログラム
```

仕組みは単純な **`ssh -Y` の X11 転送**。Vivado の Java/Swing GUI は X11 を話し、XQuartz が X サーバになる。VNC もデスクトップ環境も仮想 GPU も不要で、VM は headless 構成に arm64 の小パッケージ4つ(`xauth`、フォント、`xdpyinfo`)を足しただけ。GUI セッション中はアイドル自動終了は働かない。

- **XQuartz 2.8.6 以上が必須**。古い版は macOS 27 で `xauth` が落ちる([XQuartz#520](https://github.com/XQuartz/XQuartz/issues/520))— これは ssh の転送でまさに使う処理。2.8.7 beta は 27.0.1 でクラッシュ([#524](https://github.com/XQuartz/XQuartz/issues/524))。`gui-setup` は `brew install --cask xquartz`(現在ちょうど 2.8.6)を使い、手動インストール版が邪魔なら[公式のアンインストール手順](https://www.xquartz.org/FAQs.html)を表示する。Homebrew が無い場合は署名済み pkg を取得し SHA-256 を検証して入れる
- XQuartz 初回導入後は一度ログアウト/ログイン(launchd が `DISPLAY` を設定する)
- GUI の「Run Synthesis / Implementation」は `launch_runs`(子プロセス)経由で、Rosetta 下で壊れやすい既知の経路。落ちる場合はビルドだけ in-process Tcl で回し、GUI はプロジェクト構成・IP Integrator・回路図/デバイスビュー・Hardware Manager に使う
- 既知の癖: 真っ黒なウィンドウはリサイズすると描画される。macOS 27 の Mission Control は X11 ウィンドウを最小化できない([#519](https://github.com/XQuartz/XQuartz/issues/519)、Apple 側のバグ)。描画はネイティブより遅い
- **状態: 実装済み、実機未検証**(2026-10)。headless フローには影響しない

VM は**常駐しない**: コマンド実行時に自動起動(約30秒)し、アイドル15分で自動終了する。
連続作業中(コマンド実行中)は終了しない。挙動は `vivado-mac setup --idle 分数` で変更
(`0` = 常駐、明示的に `vivado-mac stop` するまで動き続ける)。

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
- USB JTAG 書き込みは非対応。ビットストリームは `/work` に出るので、
  書き込みは openFPGALoader(Mac ネイティブ)等を利用
- Apple は Rosetta 2 の一般提供を macOS 27 まで保証(WWDC 2025)。macOS 28 以降は要注視

## 状態ファイル

すべて `~/.vivado-mac/` に置かれる(VMディスク `disk.img`、設定 `config.json`、ログ `console.log` /
`vmhost.log`、SSH鍵)。`vivado-mac destroy` で全削除。

## 参考

- [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) /
  [minorin22 fork](https://github.com/minorin22/vivado-on-silicon-mac) — Docker + VNC による GUI 版の先行実装
- [andrivet/vivado-on-silicon-mac-x11](https://github.com/andrivet/vivado-on-silicon-mac-x11) — XQuartz で Vivado GUI を Mac デスクトップに出した先行例(Docker + TCP 直結。本ツールは ssh -Y)
- UG973 (2026.1): 対応 OS は Ubuntu 22.04/24.04, RHEL 8/9/10 ほか
