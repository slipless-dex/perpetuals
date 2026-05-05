<div align="center">
  <a href="https://slipless.xyz">
    <img src=".github/logo.svg" width="140" alt="Slipless" />
  </a>
</div>

<h1 align="center">@slipless/perpetuals</h1>

<p align="center"><strong>Solidity perp engine — positions, lazy funding, permissionless liquidations.</strong></p>

<p align="center">
  <a href="https://github.com/slipless-dex/perpetuals/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/slipless-dex/perpetuals/ci.yml?branch=main&style=flat-square&color=5cd8ff&label=ci"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-ff6bdb?style=flat-square"></a>
  
</p>

<p align="center">
  <a href="https://slipless.xyz">Site</a> &middot;
  <a href="https://app.slipless.xyz">App</a> &middot;
  <a href="https://docs.slipless.xyz">Docs</a> &middot;
  <a href="https://twitter.com/slipless">Twitter</a>
</p>

---

Solidity perpetual-futures engine. Position bookkeeping, lazy funding accrual, liquidation gating. Settled by `LimitOrderProtocol` calling into `PerpEngine.settle(...)`.

## Layout

```
src/
  PerpEngine.sol         positions, collateral, settle()
  Liquidator.sol         permissionless liquidation gate
  libraries/PerpMath.sol notional, PnL, funding (mirrors @slipless/sdk math/*)
test/
  PerpMath.t.sol         math identity tests
```

## License

MIT © Slipless Labs
