# Protocolo v0 · iPhone → PC pelo cabo

Contrato entre o app (`iphone-app/`) e o gravador (`receptor/`). Mudou aqui, avisa o receptor.

## Conexão
- O app escuta TCP em **127.0.0.1:7878 do iPhone** (só loopback: pela Wi-Fi não abre).
- O PC chega lá pelo usbmux (Apple Mobile Device Service). Teste rápido com o `pymobiledevice3`:
  `pymobiledevice3 usbmux forward 7878 7878` e conectar em `127.0.0.1:7878` no PC.
- Um PC por vez. Conexão nova derruba a anterior.
- Só o iPhone fala. O que o PC mandar é ignorado (reservado pra controle no futuro).

## Fluxo
1. `IPCM` (4 bytes ASCII) logo ao conectar.
2. Pacote **config** (tipo 1).
3. Pacotes **vídeo** (tipo 2). O primeiro é sempre quadro-chave.
4. Se o usuário trocar resolução, codec ou fps no iPhone: novo config, PTS volta a 0, próximo vídeo é
   quadro-chave. O receptor fecha o arquivo e abre outro.

## Pacote (cabeçalho de 16 bytes, big-endian)

| byte | tamanho | campo |
|---|---|---|
| 0 | 1 | tipo: 1 = config, 2 = vídeo |
| 1 | 1 | flags: bit 0 = quadro-chave |
| 2 | 2 | reservado (0) |
| 4 | 4 | tamanho do payload (u32) |
| 8 | 8 | PTS em microssegundos (i64), 0 no primeiro quadro da conexão |
| 16 | N | payload |

- **Config**: JSON UTF-8, ex.: `{"bitrate":60000000,"codec":"hevc","fps":30,"height":2160,"proto":1,"width":3840}`.
  `codec` é `h264` ou `hevc`.
- **Vídeo**: um quadro em Annex B (NALs com `00 00 00 01`). Quadro-chave traz VPS/SPS/PPS na frente.
  Sem B-frames: PTS = DTS, ordem de chegada = ordem de exibição.

## O que o receptor faz com isso
- Gravar sem re-encode: payloads em sequência formam um `.h264`/`.h265` válido; o PTS de cada pacote
  vai pro muxer (MKV/MP4) com `-c copy`. Sem o PTS, `ffmpeg -f hevc -r <fps> -i -` também serve,
  mas perde o tempo real de cada quadro.
- Quadros que o cabo não deu conta são descartados no iPhone até o próximo quadro-chave (no máximo 2 s).
  O PTS mostra o buraco.
