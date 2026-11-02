import io
import json
import logging
import os

import oci
from fdk import response

logger = logging.getLogger()


def handler(ctx, data: io.BytesIO = None):
    signer = oci.auth.signers.get_resource_principals_signer()
    budget_id = os.environ["BUDGET_ID"]
    compartment_id = os.environ["COMPARTMENT_ID"]

    # Todo alerta do budget (10%, 50%, forecast...) chega aqui; só age se o gasto real estourou.
    budget = oci.budget.BudgetClient({}, signer=signer).get_budget(budget_id).data
    spent = budget.actual_spend or 0
    if spent < budget.amount:
        logger.info("Gasto %.2f abaixo do limite %.2f; nada a fazer.", spent, budget.amount)
        return response.Response(ctx, response_data=json.dumps({"stopped": []}))

    compute = oci.core.ComputeClient({}, signer=signer)
    instances = oci.pagination.list_call_get_all_results(
        compute.list_instances, compartment_id=compartment_id, lifecycle_state="RUNNING"
    ).data

    stopped = []
    for instance in instances:
        logger.warning("Budget estourado (%.2f/%.2f): parando %s", spent, budget.amount, instance.display_name)
        compute.instance_action(instance.id, "SOFTSTOP")
        stopped.append(instance.display_name)

    return response.Response(ctx, response_data=json.dumps({"stopped": stopped}))
