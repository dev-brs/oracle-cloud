#!/usr/bin/env python3
"""Custo da tenancy OCI e guarda contra cobrança.

  oci-cost.py [report]   custo do mês atual e do anterior por SKU e uso da A1 contra a franquia Always Free
  oci-cost.py guard      dá SOFTSTOP nas VMs se a cobrança começou (ou está a ponto de começar)

O guard desliga se o custo do mês passar de --max-cost (padrão 0) OU se o uso da A1 no mês
chegar a franquia - margem. A margem (--margin-hours, padrão 24 h do shape ligado) cobre o
atraso de algumas horas nos dados de uso da OCI. --dry-run só mostra o que faria.

Autenticação: --auth config (padrão; ~/.oci/config, no PC) ou --auth instance_principal (na VM;
exige o dynamic group e a policy de bootstrap/cost_guard.tf). Requer o SDK: pip install oci
"""
import argparse
import datetime as dt
import json
import sys
import urllib.request

import oci

# Franquia Always Free da Ampere A1 por mês (equivale a 2 OCPU / 12 GB ligados o mês todo).
A1_FREE = {"B93297": 1500.0, "B93298": 9000.0}  # OCPU-hora, GB-hora
A1_NAMES = {"B93297": "A1 OCPU", "B93298": "A1 memória"}


def clients(auth, profile):
    if auth == "instance_principal":
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        cfg = {"region": signer.region}
        return cfg, signer.tenancy_id, {"signer": signer}
    cfg = oci.config.from_file(profile_name=profile)
    return cfg, cfg["tenancy"], {}


def compartments(cfg, kw, tenancy, auth, explicit):
    if explicit:
        return [explicit]
    if auth == "instance_principal":
        # A própria VM: o compartment vem do metadata service.
        req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/",
                                     headers={"Authorization": "Bearer Oracle"})
        return [json.load(urllib.request.urlopen(req, timeout=5))["compartmentId"]]
    idc = oci.identity.IdentityClient(cfg, **kw)
    subs = oci.pagination.list_call_get_all_results(
        idc.list_compartments, tenancy, compartment_id_in_subtree=True, lifecycle_state="ACTIVE").data
    return [tenancy] + [c.id for c in subs]


def instances(cfg, kw, comps):
    compute = oci.core.ComputeClient(cfg, **kw)
    out = []
    for c in comps:
        out += [i for i in oci.pagination.list_call_get_all_results(compute.list_instances, c).data
                if i.lifecycle_state != "TERMINATED"]
    return compute, out


def summarized(cfg, kw, tenancy, start, end, query_type, group_by):
    usage = oci.usage_api.UsageapiClient(cfg, **kw)
    details = oci.usage_api.models.RequestSummarizedUsagesDetails(
        tenant_id=tenancy, time_usage_started=start, time_usage_ended=end,
        granularity="MONTHLY", query_type=query_type, group_by=group_by)
    return usage.request_summarized_usages(details).data.items


def month_bounds(now):
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    prev = (start - dt.timedelta(days=1)).replace(day=1)
    end = now.replace(hour=0, minute=0, second=0, microsecond=0) + dt.timedelta(days=1)
    nxt = (start + dt.timedelta(days=32)).replace(day=1)
    return prev, start, end, nxt


def collect(args):
    cfg, tenancy, kw = clients(args.auth, args.profile)
    now = dt.datetime.now(dt.timezone.utc)
    prev, start, end, nxt = month_bounds(now)

    cost = {}  # mês -> (total, moeda, [(sku, qtd, valor)])
    for it in summarized(cfg, kw, tenancy, prev, end, "COST", ["skuPartNumber", "skuName"]):
        m = it.time_usage_started.strftime("%Y-%m")
        total, cur, rows = cost.get(m, (0.0, it.currency, []))
        amount = it.computed_amount or 0.0
        rows.append((f"{it.sku_part_number} {it.sku_name}", it.computed_quantity or 0.0, amount))
        cost[m] = (total + amount, it.currency or cur, rows)

    a1 = {sku: 0.0 for sku in A1_FREE}
    for it in summarized(cfg, kw, tenancy, start, end, "USAGE", ["skuPartNumber"]):
        if it.sku_part_number in a1 and it.time_usage_started >= start:
            a1[it.sku_part_number] += it.computed_quantity or 0.0

    compute, insts = instances(cfg, kw, compartments(cfg, kw, tenancy, args.auth, args.compartment_id))
    running = [i for i in insts if i.lifecycle_state == "RUNNING"]
    rate = {  # consumo por hora das A1 ligadas agora
        "B93297": sum(i.shape_config.ocpus for i in running if i.shape == "VM.Standard.A1.Flex"),
        "B93298": sum(i.shape_config.memory_in_gbs for i in running if i.shape == "VM.Standard.A1.Flex"),
    }
    return dict(now=now, start=start, nxt=nxt, cost=cost, a1=a1, rate=rate,
                compute=compute, insts=insts, running=running)


def report(args):
    d = collect(args)
    print("== Instâncias")
    for i in d["insts"]:
        sc = i.shape_config
        print(f"  {i.display_name:<20} {i.shape:<22} {sc.ocpus:g} OCPU / {sc.memory_in_gbs:g} GB  {i.lifecycle_state}")

    for m in sorted(d["cost"]):
        total, cur, rows = d["cost"][m]
        print(f"\n== Custo {m}: {total:.2f} {cur}")
        for sku, qty, amount in sorted(rows, key=lambda r: -r[2]):
            if amount or qty:
                print(f"  {amount:>10.2f}  {sku}  (qtd {qty:,.1f})")

    hours_left = (d["nxt"] - d["now"]).total_seconds() / 3600
    print(f"\n== Franquia A1 em {d['now']:%Y-%m} (dados de uso atrasam algumas horas)")
    for sku, free in A1_FREE.items():
        used, rate = d["a1"][sku], d["rate"][sku]
        line = f"  {A1_NAMES[sku]:<11} {used:>8,.1f} / {free:,.0f} ({used / free:.0%})"
        if rate and used + rate * hours_left > free:
            eta = d["now"] + dt.timedelta(hours=max(free - used, 0) / rate)
            line += f"  -> acaba em {eta:%d/%m %H:%M} UTC no ritmo atual"
        elif rate:
            line += f"  -> fecha o mês em ~{used + rate * hours_left:,.0f} (ok)"
        print(line)


def guard(args):
    d = collect(args)
    reasons = []
    total = sum(v[0] for m, v in d["cost"].items() if m == d["now"].strftime("%Y-%m"))
    if total > args.max_cost:
        reasons.append(f"custo do mês {total:.2f} > {args.max_cost:g}")
    for sku, free in A1_FREE.items():
        used, margin = d["a1"][sku], d["rate"][sku] * args.margin_hours
        if d["rate"][sku] and used >= free - margin:
            reasons.append(f"{A1_NAMES[sku]} {used:,.1f}/{free:,.0f} (margem {margin:,.0f})")

    if not reasons:
        print(f"ok: custo do mês {total:.2f}; A1 {d['a1']['B93297']:,.1f} OCPU-h, "
              f"{d['a1']['B93298']:,.1f} GB-h; nada a fazer")
        return
    print("COBRANÇA: " + "; ".join(reasons))
    if not d["running"]:
        print("nenhuma VM ligada")
    for i in d["running"]:
        if args.dry_run:
            print(f"[dry-run] desligaria {i.display_name} ({i.id})")
        else:
            print(f"desligando {i.display_name} ({i.id})")
            d["compute"].instance_action(i.id, "SOFTSTOP")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", nargs="?", choices=["report", "guard"], default="report")
    p.add_argument("--auth", choices=["config", "instance_principal"], default="config")
    p.add_argument("--profile", default="DEFAULT", help="perfil do ~/.oci/config")
    p.add_argument("--compartment-id", help="só as VMs deste compartment (padrão: todas; na VM, a dela)")
    p.add_argument("--max-cost", type=float, default=0.0, help="custo do mês tolerado (moeda da conta)")
    p.add_argument("--margin-hours", type=float, default=24.0, help="horas de folga antes da franquia A1")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    (guard if args.command == "guard" else report)(args)


if __name__ == "__main__":
    try:
        main()
    except oci.exceptions.ServiceError as e:
        sys.exit(f"erro da OCI: {e.status} {e.code}: {e.message}")
