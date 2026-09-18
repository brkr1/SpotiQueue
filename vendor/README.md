# Vendored third-party code

Copied into the tree so the tweak builds without extra submodules. Not
covered by this repository's MIT license, each remains under its original
author's terms.

| Directory | Project | Author | Source |
|---|---|---|---|
| `LightMessaging/` | LightMessaging, header-only mach IPC for jailbroken iOS | Ryan Petrich | https://github.com/rpetrich/lightmessaging |

The tweak links nothing as a binary: LightMessaging is header-only. libSandy
(`com.opa334.libsandy`) is a `control` dependency, loaded at runtime via
`dlopen`, same technique as NextUp3's `NUApplySandbox()`.
