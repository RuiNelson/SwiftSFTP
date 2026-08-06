# Nova feature: multiUpload e multiDownload resumíveis

## Overview

Queremos tornar possível que uploads e downloads que utilizam múltiplas conexões sejam totalmente parados e resumíveis posteriormente.

Contudo, não queremos guardar o estado da transferência do ficheiro localmente, no caso de um upload, ou num local diferente como uma base de dados, no caso de um download.

Para isso, vamos escrever no ficheiro temporário de destino (transferências serão sempre atómicas), um trailer que vai armazenar informação que eventualmente permitirá retomar a transferência mais tarde, mesmo depois de:

- transferência cancelada
- aplicação crashar

Primeiro, o ficheiro de destino será um ficheiro temporário, com um nome temporário. Quando todos os dados estiverem no servidor SFTP, ou no armazenamento local, o trailer será truncado, e depois disso, o ficheiro será renomeado para o seu nome final.

O `multiDownload` actual escreve directamente no URL final; a versão resumível passa também ela a ser atómica, o ficheiro local só aparece com o nome definitivo no fim.

## O Trailer

O trailer começa para lá do fim do payload (por exemplo, se o ficheiro a transferir tiver 1000 bytes, começa no 1001.º byte, offset 1000) e estende-se até ao fim do ficheiro — **o trailer é o footer, não existem bytes de folga depois dele**. É binário e é constituído pelos seguintes componentes:

{ Palavra Mágica, Meta-Informação, Bitmap }

Portanto, em qualquer instante:

```
tamanhoTotalDoFicheiro == tamanhoDoPayload + 10 + tamanhoDaMetaInformação + tamanhoDoBitmap
```

Em caso de um trailer defeituoso, o ficheiro é tratado como corrompido, automaticamente apagado e a transmissão recomeça do zero, sem lançar excepção.

### Localização do trailer

A palavra mágica serve apenas para **começar** a validação: dá o ponto de partida a partir do qual se tenta interpretar o trailer. O procedimento de abertura de um ficheiro parcial é:

1. `stat` do ficheiro temporário para obter o tamanho total.
2. Ler os últimos `min(tamanhoTotal, 64 KiB)` bytes.
3. Procurar a palavra mágica **do fim para o início** dessa janela.
4. Para cada candidato no offset `o` (offset absoluto no ficheiro), tentar interpretar o trailer e aceitar apenas se **todas** estas condições se verificarem:
   - o campo `Tamanho do ficheiro` (`0x0003`) é exactamente igual a `o`;
   - `o + 10 + tamanhoDaMetaInformação + tamanhoDoBitmap == tamanhoTotal`;
   - a meta-informação é válida (ver regras abaixo).
5. Se nenhum candidato passar, o ficheiro é tratado como corrompido.

A janela de 64 KiB é sempre suficiente: o trailer máximo possível ocupa 36 914 bytes (10 da magic + 4 136 de meta-informação no pior caso + 32 768 de bitmap). Um nome de ficheiro acima de 4 096 bytes é tratado como corrupção, o que fixa esse limite.

A dupla verificação (`0x0003 == o` **e** o fecho de contas do tamanho total) torna irrelevante a hipótese de a palavra mágica aparecer por acaso dentro do payload.

### Palavra Mágica

A sequência de 10 bytes codificados em ASCII:

{ End Of Transmission (0x04), 'S', 'w', 'i', 'f', 't', 'S', 'F', 'T', 'P' }

Deverá ser escrita **uma única vez**, na criação do ficheiro temporário, e logo **após** o resto do trailer ter sido escrito. Identifica que o ficheiro em questão é o ficheiro incompleto de uma transferência que pode ser retomada.

Isto quer dizer que a ordem de arranque de uma transferência nova é:

1. criar o ficheiro temporário e pré-alocá-lo com `tamanhoDoPayload + tamanhoDoTrailer` bytes;
2. escrever a meta-informação e o bitmap (todo a zeros);
3. escrever a palavra mágica;
4. só então arrancar com os workers.

Um crash antes do passo 3 deixa um ficheiro sem magic, que é tratado como corrompido e apagado — não se perde nada, porque ainda não tinha sido transferido nenhum bloco.

A palavra mágica e a meta-informação **não** são reescritas durante a transferência. As sincronizações periódicas escrevem apenas o bitmap.

### Meta-Informação

Uma estrutura de dados com um número arbitrário de elementos, cada elemento segue o seguinte formato:

{ Chave do Campo (UInt16), Tamanho do campo em bytes (UInt16), Valor do Campo (n bytes) }

O tamanho do campo é omitido quando os valores do campo têm comprimento fixo.

#### Campos obrigatórios

| Chave | Valor da Chave (hex) | Comprimento Fixo | Tipo | Descrição |
|-------|----------------------|------------------|------|-----------|
| Versão | `0x0001` | Sim | UInt16 | Versão do trailer. Actualmente `1` |
| Nome do ficheiro | `0x0002` | Não | String | Nome final do ficheiro (apenas o último componente, sem directoria) |
| Tamanho do ficheiro | `0x0003` | Sim | UInt64 | Tamanho final do ficheiro, em bytes, sem contar com o trailer |
| Escala do bitmap | `0x0004` | Sim | UInt64 | Tamanho, em bytes, que corresponde a um bloco (um bit) do bitmap |
| Data de modificação da origem | `0x0005` | Sim | UInt64 | `mtime` da origem em segundos desde 1970-01-01 UTC |
| Fim da meta-informação | `0xFFFF` | Sim | — | Marcador de terminação, sem comprimento e sem valor. O bitmap começa nos 2 bytes seguintes |

* Todos os valores numéricos usam **big-endian**
* As strings (como o nome do ficheiro) não têm null terminator, são delimitadas pelo valor do comprimento da string. São sempre codificadas usando UTF-8
* A ordem dos campos não é fixa, mas o campo `Versão` deve ser escrito em primeiro lugar para que um leitor possa rejeitar cedo um trailer de versão desconhecida
* Cada campo aparece no máximo uma vez. Um campo repetido é corrupção
* A ausência de qualquer campo obrigatório ou do terminador `0xFFFF` é corrupção
* Uma chave desconhecida é corrupção. Como o comprimento pode ser omitido, um leitor não consegue saltar um campo que não conhece — é por isso que o campo `Versão` existe e é lido primeiro

#### Compatibilidade de versões

| Situação | Comportamento |
|----------|---------------|
| `versão == 1` | Retoma normalmente |
| `versão > 1` | Lança `FileTransferErrors.resumableTrailerVersionUnsupported`. O ficheiro temporário **não** é apagado, porque pertence provavelmente a uma versão mais recente da biblioteca a transferir o mesmo ficheiro |
| Trailer corrompido | Ficheiro apagado, transferência recomeça do zero |

Quem quiser forçar a passagem por cima de um trailer de versão desconhecida usa o argumento `doNotResume: true`, que apaga o temporário antes de sequer o tentar ler.

### Bitmap

Um mapa de blocos que representa os blocos que estão transferidos e aqueles que não estão. Cada byte representa 8 blocos (um por cada bit), o tamanho do bloco é definido na meta-informação.

- Os blocos são indexados a partir de 0
- O bloco 0 é o **bit mais significativo** (`0x80`) do primeiro byte, o bloco 1 é o `0x40`, e assim sucessivamente (**MSB-first**)
- `númeroDeBlocos = ceil(tamanhoDoFicheiro / escala)`
- `tamanhoDoBitmapEmBytes = ceil(númeroDeBlocos / 8)`, e é sempre exactamente este valor — deriva-se da meta-informação, não é preciso guardá-lo
- O último bloco é parcial quando o tamanho do ficheiro não é múltiplo da escala: cobre `tamanhoDoFicheiro − (númeroDeBlocos − 1) × escala` bytes
- O bitmap cobre apenas o payload; os bytes do próprio trailer não têm bit
- Os **bits** não usados do último byte levam zero-padding, mas o seu valor é indiferente na leitura

Se o número de bytes do bitmap não corresponder ao número de blocos implicado pelo tamanho do ficheiro e pela escala, o trailer é tratado como corrupto.

Um 1 simboliza que esse bloco já foi transferido.

Um 0 simboliza que esse bloco não foi transferido. Mas também pode simbolizar que o estado é indefinido (bloco transferido, mas bitmap não foi atualizado), por isso, é melhor defensivamente tratar como não transferido.

**Os bits só transitam de 0 para 1, nunca ao contrário.** É essa monotonia que dispensa qualquer checksum no bitmap: uma escrita interrompida a meio deixa um prefixo novo e um sufixo antigo, e o resultado da mistura continua a ser um bitmap válido e conservador.

O Bitmap utiliza **até** 32 KiB (262 144 bits), convenientemente o tamanho de um bloco SFTP, o que significa que uma sincronização completa cabe sempre numa única escrita.

### Escala do bitmap

A escala não é configurável pelo chamador. É calculada uma vez, na criação do ficheiro temporário, a partir do tamanho do ficheiro e do número de workers pedido:

```
desejada   = min(10 MiB, max(1, tamanhoDoFicheiro / workers))
mínimaPeloBitmap = ceil(tamanhoDoFicheiro / 262144)     // para o bitmap caber em 32 KiB
escala     = arredondarParaCimaAMúltiploDe8(max(desejada, mínimaPeloBitmap))
```

Os 10 MiB limitam quanto trabalho se perde por bloco em curso quando há um crash. O piso `tamanhoDoFicheiro / workers` existe porque **os blocos são entregues inteiros aos workers**: sem ele, um ficheiro de 8 MiB teria um único bloco e usaria um único worker, por mais workers que fossem pedidos.

Note-se que os 10 MiB **não são um tecto absoluto**: o piso imposto pelo limite de 32 KiB do bitmap passa-lhes à frente acima de ~2,5 TiB, e é por isso que a linha dos 4 TiB da tabela abaixo dá 16 MiB. Note-se também que, para `tamanhoDoFicheiro < workers`, a divisão inteira colapsa a escala desejada em 1 e o ficheiro fica com um único bloco — a intenção de "manter todos os workers ocupados" não se aplica a ficheiros minúsculos, porque não pode haver mais blocos do que bytes.

| Ficheiro | Workers | Escala | Blocos | Bitmap |
|----------|---------|--------|--------|--------|
| 8 MiB | 4 | 2 MiB | 4 | 1 byte |
| 100 bytes | 4 | 32 bytes | 4 | 1 byte |
| 1 GiB | 8 | 10 MiB | 103 | 13 bytes |
| 4 TiB | 8 | 16 MiB | 262 144 | 32 KiB |

Numa **retoma**, a escala gravada no trailer manda sempre, mesmo que o chamador peça agora um número de workers diferente. O número de workers pedido apenas limita o paralelismo; nunca recalcula a escala, porque isso invalidaria o bitmap existente.

## Detalhes de implementação

### Nome do ficheiro

O nome do ficheiro faz-se com

```
<hash>.rmt.tmp
```

Em que a hash é o SHA256 do nome que vai ser o final do ficheiro, **truncado aos primeiros 16 bytes (128 bits)**, codificado em **Base32 Crockford, maiúsculas, sem padding** (26 caracteres, dando um nome total de 34 caracteres).

Truncar é a forma sancionada de encurtar um digest — não existe "SHA-128"; o próprio SHA-512/256 é um SHA-512 truncado. E 128 bits chegam de sobra aqui, porque **o digest é apenas uma chave de lookup e nunca uma fronteira de segurança**: um parcial só é adoptado depois de o nome final gravado *dentro* do trailer também bater certo com o destino, logo nem uma colisão forjada consegue colar duas transferências. A comparação de nomes rejeita-a, o parcial é apagado, e a transferência recomeça — o mesmo caminho de qualquer outra falha de identidade.

Assim, o SwiftSFTP pode encontrar o ficheiro incompleto sem utilização de uma base de dados, por exemplo.

Foi escolhido Base32 porque o SFTP pode estar a operar em servidores com sistemas de ficheiro case-insensitive.

O SHA256 deve ser dado pela biblioteca OpenSSL já utilizada.

O hash é feito sobre **apenas o último componente do caminho** (o nome do ficheiro, sem directoria), e o ficheiro temporário vive **na mesma directoria do destino**. Dois destinos com o mesmo nome em directorias diferentes não colidem.

### Identidade da origem

Uma retoma só é aceite se, além da hash do nome bater certo, também baterem:

- o **tamanho** da origem contra o campo `0x0003`;
- o **`mtime`** da origem contra o campo `0x0005`.

Se algum não bater, o ficheiro temporário é tratado como se fosse de outra transferência: é apagado e a transferência recomeça do zero.

> **Perigo documentado.** Isto reduz muito, mas não elimina, o risco de misturar conteúdos. Um ficheiro de origem que seja alterado mantendo exactamente o mesmo tamanho **e** o mesmo `mtime` (por exemplo, restaurado por uma ferramenta que preserva timestamps) será retomado como se nada tivesse mudado, e o resultado final terá uma parte do conteúdo antigo e outra do novo. Só um hash do conteúdo completo eliminaria esta janela, e isso obrigaria a ler o ficheiro inteiro antes de cada transferência. Documentar na API pública.

Para uploads o `mtime` vem de `FileManager.attributesOfItem(atPath:)[.modificationDate]`; para downloads vem de `FileAttributes.modificationTime` do `stat` remoto. Em ambos os casos é truncado a segundos inteiros, porque é essa a resolução do `mtime` em SFTP.

### Mecanismo de sincronização

A biblioteca cria um objeto (um `actor`) que é comum a todos os workers e que serve para efeitos de sincronismo. Os workers informam ao objeto quais os blocos completados e perguntam onde trabalhar.

O objecto mantém **dois** bitmaps em memória:

- o bitmap de blocos **completos**, que é o que vai para o ficheiro;
- o bitmap de blocos **entregues** a um worker, que serve só para não entregar o mesmo bloco duas vezes e nunca é persistido. Numa retoma, arranca todo a zeros.

Quando um worker pede trabalho, recebe o índice do primeiro bloco que não esteja nem completo nem entregue; quando não houver nenhum, o worker termina.

Os workers não carregam para a memória um bloco inteiro, mas um chunk de tamanho personalizável na chamada do método (`bufferSize`). O `bufferSize` não precisa de dividir a escala do bloco de forma exacta.

Este objeto tem uma tarefa com o seu próprio worker que se encarrega de sincronizar o trailer do servidor. **Num upload, essa tarefa tem a sua própria ligação SFTP**, para não serializar com as escritas de dados: um upload com `workers: N` pede `N + 1` ligações. Num **download** não há ligação extra — o trailer é local, e a escrita do bitmap não disputa nada com a rede; um download com `workers: N` pede `N` ligações, todas a ler a origem.

"Pede", não "abre": tal como no `multiUpload` actual, se uma ligação adicional não conseguir autenticar-se, não se tentam mais nenhumas e a transferência continua em silêncio com as que já estão de pé. O número é um pedido, não uma garantia.

A sincronização com o servidor não é imediata, nem bloqueante, ocorre de 2 em 2 segundos (não configurável) e, se o trailer estiver "dirty", também ocorre no cancelamento da transferência. A mesma cadência de 2 segundos aplica-se aos downloads, apesar de aí a escrita ser local.

Na sincronização, o objecto não precisa de estar a escrever o trailer completo, apenas o bitmap que é atualizado com frequência (guardar o offset do bitmap).

### Durabilidade: quando é que um bit pode ir a 1

Não se usa `fsync` por bloco: o custo por 10 MiB seria alto e nem todos os servidores suportam a extensão. Em vez disso, garante-se a ordem seguinte, que mantém o bitmap sempre **atrasado** em relação aos dados e nunca à frente:

1. Um worker só reporta um bloco como completo depois de a **última escrita desse bloco ter retornado com sucesso**.
2. O sincronizador só marca bits de blocos que já lhe foram reportados.
3. Como a sincronização é preguiçosa (2 em 2 segundos), na prática há sempre uma folga entre a escrita dos dados e a escrita do bit correspondente, e essa folga corre no sentido seguro.
4. Como os bits só sobem de 0 para 1, uma escrita de bitmap interrompida a meio nunca produz um bitmap optimista.

Isto cobre por completo o crash da aplicação, o cancelamento, e a queda da ligação — casos em que o servidor já tem os dados. O risco residual, que se documenta e não se mitiga, é o de um servidor que confirme escritas e depois as perca (crash do próprio servidor com dados só em cache); nesse cenário o bitmap pode ficar optimista e o ficheiro final sai corrompido.

Faz-se um único `fsync()` no fim, antes da truncagem e do rename, com o erro ignorado se o servidor não suportar a extensão.

> **Contrato para quem implementa a escrita do bitmap.** O flush de encerramento — o que preserva o progresso de uma transferência cancelada — corre **dentro de uma task já cancelada**. Uma implementação que verifique cancelamento antes de escrever deita fora, em silêncio, os últimos blocos de todas as transferências canceladas, ou seja exactamente o caso que justifica a feature. Hoje isto está salvo por acidente, porque as operações SFTP da biblioteca não observam cancelamento (a única verificação na Layer 1 está no `KeepAliveLoop`), mas o closure de flush não pode acrescentar a sua.
>
> Pela mesma ordem de razões, um erro no flush é engolido e a escrita repetida no tick seguinte, nunca propagado: um bitmap que não aterra custa blocos retransmitidos na execução seguinte, nunca correcção, e a ligação de flush a morrer não deve matar uma transferência saudável.

### Conclusão da transferência

Quando todos os bits estão a 1:

1. `fsync()` (erro ignorado);
2. truncar o ficheiro para `tamanhoDoPayload`, removendo o trailer;
3. **verificar por `stat` que o tamanho ficou de facto igual ao payload**;
4. verificar que o caminho de destino final continua a não existir;
5. renomear o temporário para o nome final.

Há servidores SFTP que ignoram ou recusam um `SETSTAT` que encolha um ficheiro. Se o passo 3 revelar que a truncagem não teve efeito, lança-se `FileTransferErrors.resumableTruncateUnsupported` e **não se faz o rename**, porque produziria um ficheiro final com o trailer colado ao payload. O ficheiro temporário é preservado com o bitmap todo a 1: se a configuração do servidor for corrigida, a execução seguinte retoma-o e conclui-o sem retransmitir nada.

Se o passo 4 revelar que o destino passou a existir entretanto, lança-se `remoteFileAlreadyExists` / `localFileAlreadyExists`, como no `multiUpload` actual.

### API

```swift
func multiUploadResumable(
    from localURL: URL,
    to remotePath: String,
    workers: Int = 2,
    bufferSize: Int = 1024 * 1024,
    permissions: POSIXPermissions = [.serverDefault],
    doNotResume: Bool = false,
    continuation: @escaping TransferProgress
) async throws

func multiDownloadResumable(
    from remotePath: String,
    to localURL: URL,
    workers: Int = 2,
    bufferSize: Int = 1024 * 1024,
    doNotResume: Bool = false,
    continuation: @escaping TransferProgress
) async throws
```

- `doNotResume: true` apaga qualquer ficheiro temporário existente antes de começar, sem o tentar interpretar.
- A verificação de que o **destino final** já existe é feita primeiro, antes de se procurar o parcial.
- O progresso reportado ao `continuation` arranca nos bytes **já transferidos** (blocos a 1 no bitmap), não em zero. O total reportado é o tamanho do payload, sem contar com o trailer.
- Numa retoma, o número de workers efectivo é limitado ao número de blocos que ainda faltam.

Métodos de limpeza, para os temporários que ficaram abandonados de vez:

```swift
func cleanupResumableUploads(in remotePath: String, olderThan age: TimeInterval) async throws -> [String]
func cleanupResumableDownloads(in localURL: URL, olderThan age: TimeInterval) throws -> [URL]
```

Listam a directoria (sem recursão), filtram por sufixo `.rmt.tmp`, apagam os que tenham `mtime` mais antigo que `age` e devolvem o que apagaram. Uma directoria inexistente lança (um caminho mal escrito não se pode fazer passar por uma directoria limpa; quem não quiser saber usa `try?`); um `delete` individual que falhe é saltado sem abortar a varredura, e o valor devolvido é o registo do que desapareceu mesmo, não do que correspondeu ao filtro.

Esta é a **única operação de toda a feature que destrói progresso retomável de forma irreversível**, e por isso é a que precisa dos avisos mais fortes:

- **Não interpretam o trailer**, e por isso não distinguem um temporário abandonado de um que esteja neste preciso momento a ser escrito por outra aplicação — daí `age` não ter valor por omissão.
- **Dimensionar `age` pelo motivo errado é o erro previsível.** A intuição manda escolher "mais do que uma transferência demora", mas o `mtime` de uma transferência pausada não avança, e o objectivo da feature é precisamente que ela continue retomável durante dias. `age` mede-se contra **quanto tempo se está disposto a honrar uma transferência interrompida**, não contra a duração de uma transferência.
- **Relógios diferentes.** No caso remoto o `mtime` é do servidor e o `age` é medido no cliente. Um servidor atrasado faz temporários acabados de escrever parecerem varríveis. Fica marcado com um `ponytail:` no código, com o caminho de resolução: derivar o corte do relógio do próprio servidor, escrevendo um ficheiro sonda na directoria e lendo-lhe o `mtime` de volta.
- **Contradiz a linha `versão > 1` da tabela do ciclo de vida.** Essa linha preserva de propósito um temporário escrito por uma versão mais recente da biblioteca; a limpeza, que nunca parseia o trailer, apaga-o como a qualquer outro assim que ele tenha idade suficiente. Não tem solução sem parsear, mas as duas secções devem assumir que discordam.
- Quando o ficheiro "mutex" do primeiro edge case for implementado, **é aqui que ele mais faz falta**: nas transferências, adivinhar mal custa um recomeço; aqui custa a perda definitiva do progresso.

### Ciclo de vida do ficheiro temporário

A regra é uma só: **o ficheiro temporário sobrevive a tudo, excepto a um estado que o torne inútil.**

| Evento | Ficheiro temporário |
|--------|---------------------|
| Cancelamento ou erro, com pelo menos um bloco completo | **Preservado**, com um flush final do trailer se estiver dirty |
| Cancelamento ou erro, sem um único bloco completo | **Apagado** |
| Crash / kill da aplicação | **Preservado**, com o bitmap até à última sincronização |
| `resumableTruncateUnsupported` | **Preservado**, com o bitmap completo — é o único caso em que se preserva um payload já inteiro |
| Trailer corrompido, ou identidade da origem não bate | **Apagado**, transferência recomeça do zero |
| `versão > 1` no trailer | **Preservado**, lança excepção |
| Transferência concluída | Truncado e renomeado |

O cancelamento não tem regra própria: é o mesmo `catch` e a mesma pergunta ("há algum bloco completo?"). Uma versão anterior deste documento dava-lhe uma linha à parte que preservava sempre, o que contrariava o princípio — um temporário com zero blocos é exactamente um estado que o torna inútil, e preservá-lo deixaria no servidor um ficheiro pré-alocado do tamanho final inteiro por causa de um cancelamento imediato. Um payload **vazio** é a excepção da excepção: aí zero blocos completos significa *concluído*, não *nada feito*, e preserva-se.

Apagar em erro **não é um mecanismo de segurança**. A segurança do parcial vem das invariantes do trailer — bitmap conservador, verificação de identidade da origem, corrupção detectada e apagada, bits monótonos — e não da política de apagamento. Um parcial deixado para trás por uma queda de rede é exactamente tão fiável como um deixado por um cancelamento: em ambos os casos os bytes marcados a 1 estão confirmados pelo servidor.

Por isso preserva-se em todos os erros que possam ocorrer a meio de uma transferência:

- **queda de rede, reset, timeout, servidor desaparece** — o caso de uso central da feature;
- **`shortWrite`** (tipicamente disco cheio no servidor) — o bloco truncado nunca chega a ter o bit posto, o bitmap continua conservador;
- **`shortRead`** num download — significa que a origem remota encolheu; o `stat` da execução seguinte traz o tamanho novo e a verificação de identidade apaga o parcial sozinha;
- **erro de I/O local** — mesma lógica.

Isto inclui o servidor que não trunca. `resumableTruncateUnsupported` é lançado com o payload **inteiro** já no servidor: o utilizador pode alterar a configuração ou actualizar o software do servidor e, na execução seguinte, o mesmo parcial passa directamente ao `fsync`/truncagem/rename sem retransmitir um único byte. Apagá-lo deitaria fora uma transferência completa por causa de uma limitação reversível.

Sobra uma única excepção: um encerramento — erro **ou** cancelamento — que ocorreu **antes de existir um único bloco completo**. Aí não há nada para retomar, e apagar evita que o caso "isto simplesmente não funciona" (credenciais, permissões, servidor em baixo) deixe rasto, ou que um cancelamento imediato abandone um ficheiro pré-alocado do tamanho final.

O `multiUpload` actual apaga o temporário em qualquer falha, mas esse precedente não se aplica: lá o parcial é lixo puro, porque não existe forma de o retomar.

Notas sobre o lixo acumulado:

- O nome é determinístico, `SHA256` truncado a 128 bits do nome final. Mil tentativas falhadas do mesmo ficheiro deixam **um** temporário, não mil.
- Quem quiser tábua rasa numa execução usa `doNotResume: true`; quem quiser varrer uma directoria usa `cleanupResumableUploads` / `cleanupResumableDownloads`. Não é preciso parâmetro novo.
- Contrapartida aceite: se a falha foi por falta de espaço no servidor, o parcial continua a ocupá-lo. Apagar também não resolveria — a retentativa recomeçaria do zero e bateria na mesma parede.

### Organização do código

Tudo em `Sources/SwiftSFTP/Layer 1/Convenience/ClientMultiResumable/`:

- `Trailer.swift` — o formato: serialização, parsing, validação, cálculo da escala e do bitmap
- `Synchronizer.swift` — o `actor` de coordenação, os dois bitmaps e a tarefa periódica de flush
- `Methods.swift` — os métodos públicos em `SFTPClientProtocol`

Os erros novos entram em `Layer 1/Types/FileTransferErrors.swift`:

- `resumableTrailerVersionUnsupported(version: UInt16, path: String)`
- `resumableTruncateUnsupported(path: String)`

O SHA256 e o Base32 Crockford ficam em `Extensions/` (o SHA256 via OpenSSL, como o resto de `CryptographicUtils/`).

**Não reutilizar `ClientMulti.swift`.** Há sobreposição óbvia (`provisionMultiTransferWorkers`, `MultiTransferProgressReporter`), mas a versão resumível escreve-se autónoma; a passagem de DRY faz-se depois, com as duas implementações a funcionar e testadas.

## Edge Cases

### Dois utilizadores diferentes fazerem upload de um ficheiro com o mesmo nome ao mesmo tempo

Embora esse problema possa ser praticamente contornado com um ficheiro "mutex", isso requereria que os utilizadores utilizassem um identificador único, para saber se o "ficheiro mutex" era de outro utilizador ou deles (por exemplo, deixado por uma aplicação que crashou). Escolhemos não suportar esse edge case, e iremos endereçar esse assunto numa versão posterior. Vamos porém, adicionar documentação sobre o perigo.

O mesmo se aplica a duas transferências concorrentes para o mesmo destino a partir do mesmo processo.

### Hash do nome do ficheiro coincide, mas no payload, o nome do ficheiro, o tamanho ou o mtime não coincidem com o ficheiro de origem

O ficheiro temporário é apagado e a transferência recomeça do zero, em silêncio, exactamente como um trailer corrompido — ver a tabela do ciclo de vida, que é a autoridade. (Uma versão anterior deste documento dizia aqui que o caso era tratado como erro, "como se um ficheiro com o mesmo nome já existisse"; contradizia a tabela e estava errada.) Documentar o comportamento menos óbvio na API pública.

### Origem alterada mantendo tamanho e mtime

Ver "Identidade da origem". Não é detectável sem hash de conteúdo; documentado como limitação conhecida.

### Versão do trailer demasiado alta ou trailer corrompido

Tratados de forma diferente: versão demasiado alta lança excepção e preserva o ficheiro; trailer corrompido apaga o ficheiro e recomeça em silêncio. Ver a tabela em "Compatibilidade de versões".

### Servidor que não permite truncar

Lança `resumableTruncateUnsupported`. Ver "Conclusão da transferência".
