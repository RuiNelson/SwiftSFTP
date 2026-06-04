# 004 — `authenticate()` descarta o erro original da autenticação por senha

**Severidade:** Alta  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/StructsAndEnums/UserAuthentication.swift:19-25`

## Descrição

Para o modo `.password`, qualquer erro de `UserAuthPassword` é capturado e substituído por `SFTPClientInvalidConfig.invalidPassword`. O erro original do libssh2 é descartado, tornando impossível distinguir "senha incorreta" de "método não suportado pelo servidor" ou "erro de rede durante autenticação".

## Código Problemático

```swift
case let .password(pass):
    do {
        try UserAuthPassword(session: session, username: username, password: pass)
    }
    catch {
        throw SFTPClientInvalidConfig.invalidPassword  // erro original perdido
    }
```

## Inconsistência

Os modos `.privateKeyString` e `.privateKeyFile` propagam erros do libssh2 diretamente, sem redução. Apenas autenticação por senha perde informação de diagnóstico.

## Comportamento Esperado

O erro original deve ser preservado — seja propagado diretamente ou encapsulado num caso de erro com `associatedValue`, como `SFTPClientInvalidConfig.authenticationFailed(Error)`.

## Correção Sugerida

```swift
case let .password(pass):
    try UserAuthPassword(session: session, username: username, password: pass)
```

Ou, se for desejável distinguir erros de auth na superfície pública:

```swift
case authenticationFailed(Error)
```

e então:

```swift
catch {
    throw SFTPClientInvalidConfig.authenticationFailed(error)
}
```
