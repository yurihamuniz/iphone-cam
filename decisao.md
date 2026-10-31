# Decisão · quem captura e envia no iPhone (2026-10-31)

**Caminho principal:** app próprio em Swift, compilado no GitHub Actions e instalado pelo Sideloadly
com conta Apple gratuita. Esqueleto pronto nesta pasta (ainda não compilado).

**Plano B:** Blackmagic Camera (grátis) mandando SRT pro PC, gravado com `ffmpeg -c copy`.
Zero código, dá pra testar hoje; perde no atraso e só usa o cabo com Ponto de Acesso Pessoal.

## Por que o app próprio
- **Só ele usa o usbmux.** No usbmux quem abre a conexão é o PC, até uma porta TCP do iPhone. Apps
  prontos fazem o contrário (o iPhone conecta num servidor) e o SRT é UDP. Pelo cabo, eles só andam
  via Ponto de Acesso Pessoal por USB, que exige plano de celular com hotspot liberado.
- **Sem re-encode:** o PC recebe o H.264/HEVC do encoder de hardware do iPhone e só empacota.
- **Sem teto de plano:** 4K, HEVC e bitrate escolhidos por nós, sem marca d'água nem limite de tempo.
- **Custo zero.** O preço é a reassinatura a cada 7 dias (automatizável) e o código pra manter.

## Comparação

| | App próprio (Swift) | Blackmagic Camera | Larix Broadcaster | NDI HX, iVCam, EpocCam |
|---|---|---|---|---|
| 4K / HEVC | sim / sim (iPhone 7+ pra HEVC, 8+ pra 4K60) | grava 4K HEVC; resolução do stream não confirmada | 4K sim; HEVC só no Premium | limites no grátis ou pago |
| Bitrate | livre (padrão 20 Mbps 1080p, 60 Mbps 4K) | configurável | configurável | variável |
| Atraso | 1 a 3 quadros + cabo, ~50 a 100 ms (estimado, medir) | SRT, ~200 a 500 ms | SRT/RTMP, ~200 ms a 1 s | 100 ms a 1 s |
| Pelo cabo | sim, usbmux nativo | só via hotspot USB (precisa chip com dados) | idem | maioria Wi-Fi |
| Custo | R$ 0 | R$ 0, sem compra no app | grátis para em 30 min (+30 com marca d'água); Premium US$ 9,99/mês | NDI HX pago; outros com marca d'água |
| Manutenção | reassinar a cada 7 dias; recompilar se o iOS quebrar algo | nenhuma (App Store) | nenhuma | nenhuma |
| Grava sem re-encode no PC | sim (Annex B + PTS, `-c copy`) | sim (MPEG-TS do SRT, `-c copy`) | sim | depende |
| Esforço inicial | alto (app + receptor) | baixo | baixo | baixo |

**Open source que já faça iPhone → PC por USB em 4K:** não achei app mantido. Peças úteis:
- `rsms/peertalk`: framing por usbmux, mesmo padrão do nosso servidor (o lado PC dele não roda no Windows).
- `wtsnz/obs-ios-camera-source`: plugin aberto do OBS que recebe do iPhone por USB no Windows; o app do
  iPhone é pago e fechado. Serve de referência de arquitetura.
- `pymobiledevice3` / libimobiledevice: o lado PC do usbmux, funciona no Windows (é o que `transporte/` usa).

## Compilar sem Mac
| opção | custo | veredito |
|---|---|---|
| **GitHub Actions, runner macOS** | grátis em repo público; em privado gasta a cota do plano Free (macOS conta 10x; conferir em Settings > Billing). Build estimado em 3 a 5 min | **escolhido** |
| Codemagic | camada grátis com minutos macOS por mês | reserva se a cota apertar |
| Xcode Cloud | exige Apple Developer pago | não |
| Theos + SDK no Linux/WSL | licença do SDK duvidosa | não |

O workflow gera o `.xcodeproj` com XcodeGen (`project.yml`), compila **sem assinatura** e sobe o `.ipa`
como artifact da execução. A assinatura fica no Windows.

## Instalar no iPhone
| opção | validade | veredito |
|---|---|---|
| **Sideloadly + Apple ID gratuito** | 7 dias, até 3 apps; renova sozinho com o iPhone no cabo ou na Wi-Fi do PC | **escolhido**: o iPhone já vive plugado neste PC |
| AltStore / SideStore | 7 dias; SideStore renova pelo próprio iPhone | desnecessário aqui |
| Apple Developer US$ 99/ano | 1 ano | só se a reassinatura incomodar |

## O esqueleto (nesta pasta)
- `project.yml` · projeto Xcode em texto (iOS 16+, paisagem, permissão de câmera).
- `IPhoneCam/CameraController.swift` · câmera traseira, formato 1080p/4K a 30/60 fps, estabilização desligada.
- `IPhoneCam/VideoEncoder.swift` · VideoToolbox em tempo real, H.264 ou HEVC, sem B-frames, quadro-chave a cada 2 s; converte pra Annex B.
- `IPhoneCam/StreamServer.swift` · TCP só em 127.0.0.1:7878, um PC por vez; se o cabo atrasar, descarta até o próximo quadro-chave.
- `IPhoneCam/Packet.swift` + `protocolo.md` · o formato do que vai pelo cabo (contrato com `receptor/`).
- `IPhoneCam/ContentView.swift` · prévia, status, fps e Mbps, seletores de resolução, codec e fps.
- `.github/workflows/build-ipa.yml` · compila o `.ipa` (pressupõe `iphone-app/` como raiz do repositório).

Só codifica com o PC conectado (poupa bateria e calor).

## Próximos passos

**Você faz**
1. Dizer o modelo do iPhone e a versão do iOS (define se 4K60 e HEVC estão disponíveis).
2. Aprovar o repositório: `yurihamuniz/iphone-cam-app`, **privado** (recomendado; cabe na cota) ou público (minutos ilimitados).
3. Instalar o Sideloadly. Se ele pedir, iTunes e iCloud baixados do site da Apple, não da Microsoft Store.
4. No iPhone (iOS 16+): Ajustes > Privacidade e Segurança > Modo de Desenvolvedor > ligar (reinicia).
5. Abrir o `.ipa` no Sideloadly e entrar com o Apple ID (você digita; vale um Apple ID secundário).
   Depois: Ajustes > Geral > VPN e Gerenciamento de Dispositivo > confiar no seu Apple ID.
6. Ligar a renovação automática do Sideloadly.

**Agente faz**
1. Com o seu OK: `git init` em `iphone-app/`, criar o repo, primeiro push, rodar o workflow.
2. Corrigir o que o compilador acusar (o código ainda não passou por um) até sair o `.ipa`.
3. Teste ponta a ponta com `transporte/` e `receptor/`: `pymobiledevice3 usbmux forward 7878 7878`,
   gravar 1 min em 1080p e 4K, medir atraso, banda e quadros perdidos.
4. Ajustar bitrate e o controle de taxa (ex.: modo de baixa latência do H.264) conforme a medição.

**Plano B, se quiser um número de referência hoje**
Blackmagic Camera na App Store; no PC,
`ffmpeg -i "srt://0.0.0.0:9000?mode=listener" -c copy teste.ts`; no app, stream SRT pra
`srt://<IP do PC>:9000`. Pelo cabo: Ponto de Acesso Pessoal ligado, PC fica em 172.20.10.x.

## Prestar atenção
- Código escrito sem compilador: a primeira execução do Actions deve acusar erros pequenos.
- O app precisa ficar aberto e em primeiro plano; o iOS corta a câmera em segundo plano. A tela não apaga sozinha.
- 4K60 HEVC contínuo esquenta o iPhone. Gravação longa: 4K30, ou capinha fora e algo ventilando.
- Apple ID gratuito: 3 apps e poucos App IDs por semana. Reinstalar muito em pouco tempo pode travar a semana.
- Hotspot por USB (plano B) pode fazer o Windows usar os dados do celular pra internet.
- Instalar iTunes ao lado do app "Dispositivos Apple" mexe no Apple Mobile Device Service, que o `transporte/` usa.
  Conferir com aquela sessão antes.

Fontes: [Larix iOS](https://softvelum.com/larix/ios/), [Larix Premium](https://softvelum.com/larix/premium/),
[Blackmagic Camera 3.2 com streaming](https://petapixel.com/2025/11/06/blackmagic-camera-3-2-brings-professional-live-streaming-to-iphone),
[Hotspot da Apple](https://support.apple.com/en-uk/HT204023),
[obs-ios-camera-source](https://www.github.com/wtsnz/obs-ios-camera-source),
[preço dos runners](https://docs.github.com/en/enterprise-server@3.17/billing/reference/actions-runner-pricing).
