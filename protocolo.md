# Protocolo · iPhone ↔ PC pelo cabo

Contrato entre o app (`iphone-app/`) e o gravador (`receptor/`). Mudou aqui, avisa o receptor.

## Conexão
- O app escuta TCP em **127.0.0.1:7878 do iPhone** (só loopback: pela Wi-Fi não abre).
- O PC chega lá pelo usbmux (Apple Mobile Device Service). Teste rápido com o `pymobiledevice3`:
  `pymobiledevice3 usbmux forward 7878 7878` e conectar em `127.0.0.1:7878` no PC.
- Um PC por vez. Conexão nova derruba a anterior.
- O iPhone manda vídeo; o PC manda comandos (tipo 3, desde o `proto` 2). App com `proto` 1 ignora comando.

## Fluxo
1. `IPCM` (4 bytes ASCII) logo ao conectar.
2. Pacote **config** (tipo 1).
3. Pacotes **vídeo** (tipo 2). O primeiro é sempre quadro-chave.
4. Se o usuário trocar resolução, codec ou fps no iPhone: novo config, PTS volta a 0, próximo vídeo é
   quadro-chave. O receptor fecha o arquivo e abre outro.

## Pacote (cabeçalho de 16 bytes, big-endian)

| byte | tamanho | campo |
|---|---|---|
| 0 | 1 | tipo: 1 = config, 2 = vídeo (iPhone → PC); 3 = comando (PC → iPhone) |
| 1 | 1 | flags: bit 0 = quadro-chave |
| 2 | 2 | reservado (0) |
| 4 | 4 | tamanho do payload (u32) |
| 8 | 8 | PTS em microssegundos (i64), 0 no primeiro quadro da conexão |
| 16 | N | payload |

- **Config**: JSON UTF-8, ex.: `{"bitrate":60000000,"codec":"hevc","fps":30,"height":2160,"proto":2,"width":3840}`.
  `codec` é `h264` ou `hevc`.
- **Vídeo**: um quadro em Annex B (NALs com `00 00 00 01`). Quadro-chave traz VPS/SPS/PPS na frente.
  Sem B-frames: PTS = DTS, ordem de chegada = ordem de exibição.

## Comandos do PC (tipo 3, `proto` 2)
Mesmo cabeçalho, PTS 0, payload JSON. Todos os campos são opcionais e podem vir juntos.

| campo | valores | o que o iPhone faz |
|---|---|---|
| `gravando` | `true` / `false` | liga ou apaga a luz do flash traseiro e o REC na tela, toca o som de gravar. `true` força quadro-chave no próximo quadro |
| `luz` | `"fixa"` / `"piscar"` / `"desligada"` | como a luz traseira se comporta enquanto grava (padrão `fixa`, nível baixo) |
| `config` | `{"resolucao": "1080p" ou "4K", "fps": 30 ou 60, "codec": "h264" ou "hevc"}` | troca a captura, como se fosse na tela. Responde com config novo |

Ex.: `{"config":{"resolucao":"4K","fps":30,"codec":"hevc"}}`, `{"gravando":true}`.
Se o PC desconecta, o iPhone apaga a luz.

## O que o receptor faz com isso
- Gravar sem re-encode: payloads em sequência formam um `.h264`/`.h265` válido; o PTS de cada pacote
  vai pro muxer (MKV/MP4) com `-c copy`. Sem o PTS, `ffmpeg -f hevc -r <fps> -i -` também serve,
  mas perde o tempo real de cada quadro.
- Quadros que o cabo não deu conta são descartados no iPhone até o próximo quadro-chave (no máximo 2 s).
  O PTS mostra o buraco.
