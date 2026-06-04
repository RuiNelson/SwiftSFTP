# 012 — Label `file:` enganosa em `UserAuthenticationMode.privateKeyString`

**Severidade:** Baixa  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/StructsAndEnums/UserAuthentication.swift:10`

## Descrição

O caso `privateKeyString` usa o label `file:` para um parâmetro que é o conteúdo string da chave privada, não um caminho de arquivo. O caso `privateKeyFile` usa a mesma label `file:` para uma `URL`, onde o label é correto. A ambiguidade pode confundir usuários da API que veem os dois casos lado a lado.

## Código Problemático

```swift
public enum UserAuthenticationMode: Codable, Equatable, Sendable {
    case password(String)
    case privateKeyString(file: String, password: String?)  // ← "file" é o conteúdo, não o caminho
    case privateKeyFile(file: URL, password: String?)       // ← "file" é a URL — correto
}
```

## Impacto

- Usuários que leem a assinatura podem passar um caminho de arquivo onde é esperado o conteúdo da chave.
- O erro seria silencioso (a string seria interpretada como dados PEM, falhando apenas na autenticação).

## Correção Sugerida

Renomear o label para refletir o conteúdo real:

```swift
case privateKeyString(keyData: String, password: String?)
```

Isso requer atualização de todos os call sites e é uma mudança de API pública — avaliar versioning conforme `etc/Release Template.md`.
