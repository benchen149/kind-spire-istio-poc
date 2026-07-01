#!/usr/bin/env bash
# Helm post-renderer: three patches on the istio-ingress Helm chart output.
#
# 1. workload-socket emptyDir → csi.spiffe.io
#    Chart hardcodes emptyDir; kustomize strategic merge merges fields producing
#    invalid spec (emptyDir + csi coexist), so Python replace is used.
#
# 2. CA_ADDR + PILOT_CERT_PROVIDER env override → SPIRE socket
#    values.yaml keeps pilotCertProvider=istiod so chart retains istiod-ca-cert
#    volume (needed for xDS TLS); post-renderer then redirects the workload cert
#    path to SPIRE without touching the xDS control-plane CA.
#
# 3. SA name: *-service-account → validation-gateway-sa
#    OPA enforce-sa-naming requires ^[a-z0-9-]+-(?:gateway|...)-sa$;
#    chart derives SA name as "{{ gateway.name }}-service-account" with no override.
set -euo pipefail

OLD_SA="validation-ingressgateway-service-account"
NEW_SA="validation-gateway-sa"

python3 -c "
import sys, yaml

OLD_SA = '$OLD_SA'
NEW_SA = '$NEW_SA'
SPIRE_SOCKET = 'unix:///run/secrets/workload-spiffe-uds/socket'

def patch(doc):
    if not doc:
        return doc
    kind = doc.get('kind', '')

    if kind == 'Deployment':
        spec = doc['spec']['template']['spec']

        # 1. Replace workload-socket emptyDir with CSI volume
        for i, v in enumerate(spec.get('volumes', [])):
            if v.get('name') == 'workload-socket':
                spec['volumes'][i] = {'name': 'workload-socket',
                                      'csi': {'driver': 'csi.spiffe.io', 'readOnly': True}}
                break

        # 2. Override CA_ADDR + PILOT_CERT_PROVIDER on all containers
        for c in spec.get('containers', []):
            for env in c.get('env', []):
                if env.get('name') == 'CA_ADDR':
                    env['value'] = SPIRE_SOCKET
                elif env.get('name') == 'PILOT_CERT_PROVIDER':
                    env['value'] = 'spiffe'

        # 3a. Update Deployment serviceAccountName
        if spec.get('serviceAccountName') == OLD_SA:
            spec['serviceAccountName'] = NEW_SA

    # 3b. Rename ServiceAccount
    elif kind == 'ServiceAccount':
        if doc.get('metadata', {}).get('name') == OLD_SA:
            doc['metadata']['name'] = NEW_SA

    # 3c. Update RoleBinding subject
    elif kind in ('RoleBinding', 'ClusterRoleBinding'):
        for subj in doc.get('subjects', []):
            if subj.get('kind') == 'ServiceAccount' and subj.get('name') == OLD_SA:
                subj['name'] = NEW_SA

    return doc

for doc in yaml.safe_load_all(sys.stdin):
    if doc:
        print('---')
        sys.stdout.write(yaml.dump(patch(doc), default_flow_style=False))
"
