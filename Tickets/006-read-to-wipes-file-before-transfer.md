# 006 — `read(to:)` apaga o arquivo local antes de iniciar a transferência

**Severidade:** Alta  
**Status:** Resolvido (comportamento alterado: falha se o ficheiro local já existir)  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/Convenience/FileUploadDownload.swift:99`

## Descrição

A função `read(to:file:bufferSize:continuation:)` usa `try Data().write(to: file)` para criar ou truncar o arquivo de destino **antes** de qualquer leitura remota. Se a transferência SFTP falhar imediatamente (ex.: erro de `fstat`, erro de leitura, cancelamento), o arquivo local já foi destruído e não há rollback.

## Código Problemático

```swift
try Data().write(to: file)           // ← arquivo local zerado aqui
let localFileHandle = try FileHandle(forWritingTo: file)

// ... se qualquer coisa abaixo lançar, o arquivo local já está vazio
let fileSize = try await stat.fileSize
while let data = try await read(upTo: bufferSize) {
    ...
}
```

## Impacto

- Um arquivo local pré-existente é destruído em caso de qualquer falha no servidor ou rede.
- O chamador não tem como recuperar o conteúdo anterior.

## Comportamento Esperado

O arquivo local deve ser criado (ou sobrescrito) apenas após a transferência bem-sucedida, ou o arquivo original deve ser preservado se a transferência falhar.

## Correção Sugerida

Uma abordagem segura é escrever para um arquivo temporário e mover atomicamente apenas em caso de sucesso:

```swift
let tempURL = file.deletingLastPathComponent()
    .appendingPathComponent(".sftptmp-\(UUID().uuidString)")

defer { try? FileManager.default.removeItem(at: tempURL) }

try Data().write(to: tempURL)
let localFileHandle = try FileHandle(forWritingTo: tempURL)
defer { try? localFileHandle.close() }

// ... transferência ...

try FileManager.default.moveItem(at: tempURL, to: file)
```
