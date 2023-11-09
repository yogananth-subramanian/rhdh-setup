#!/bin/bash
set -uo pipefail
[ -z ${QUAY_TOKEN} ]
[ -z ${GITHUB_TOKEN} ]

NAMESPACE=janus
JANUS_HELM_CHART=janus

delete (){
    for cr in keycloakusers keycloakclients keycloakrealms keycloaks; do
        for res in $(oc get $cr.keycloak.org -n janus -o name); do 
            oc patch $res -n ${NAMESPACE} -p '{"metadata":{"finalizers":[]}}' --type=merge
            oc delete $res -n ${NAMESPACE} --wait;
        done;
    done
    helm uninstall ${JANUS_HELM_CHART}
    oc delete pvc data-janus-postgresql-0 --ignore-not-found
    oc delete project ${NAMESPACE} --wait
}

keycloak_install (){
    oc new-project ${NAMESPACE}
    oc project ${NAMESPACE} 
    export KEYCLOAK_CLIENT_SECRET=`mktemp -u XXXXXXXXXX`
    oc apply -f template/keycloak/keycloak-op.yaml
    grep -m 1 "rhsso-operator" <(oc get pods -w )
    oc wait --for=condition=Ready pod  -l=name=rhsso-operator -n ${NAMESPACE} --timeout=300s
    oc apply -f template/keycloak/keycloak.yaml
    grep -m 1 "keycloak-0" <(oc get pods -w )
    oc wait --for=condition=Ready pod/keycloak-0  -n ${NAMESPACE} --timeout=300s
    oc apply -f template/keycloak/keycloakRealm.yaml
    cat template/keycloak/keycloakClient.yaml| envsubst '${OPENSHIFT_APP_DOMAIN} ${KEYCLOAK_CLIENT_SECRET}'|kubectl apply -f -
    oc apply -f template/keycloak/keycloakUser.yaml
    oc -n ${NAMESPACE} get secret credential-example-sso -o template --template='{{.data.ADMIN_PASSWORD}}'|base64  -d
}

backstage_install (){
    until cat template/backstage/secret-rhdh-pull-secret.yaml| envsubst '${QUAY_TOKEN}'|kubectl apply -f -;do oc delete secret rhdh-pull-secret;done
    cat template/backstage/app-config.yaml|envsubst '${GITHUB_TOKEN} ${OPENSHIFT_APP_DOMAIN} ${KEYCLOAK_CLIENT_SECRET}' > app-config.yaml
    until oc create configmap app-config-rhdh --from-file "app-config-rhdh.yaml=app-config.yaml" -n ${NAMESPACE}; do oc delete configmap app-config-rhdh;done
    helm repo update openshift-helm-charts
    cat template/backstage/chart-values.yaml | envsubst '${OPENSHIFT_APP_DOMAIN}' | helm upgrade --install ${JANUS_HELM_CHART}  openshift-helm-charts/redhat-developer-hub -n ${NAMESPACE} --values -
    grep -m 1 "janus-developer-hub" <(oc get pods -w )
    oc wait --for=condition=Ready pod  -l=app.kubernetes.io/name=developer-hub -n ${NAMESPACE} --timeout=300s
}

install (){
    appurl=`oc whoami --show-console`
    export OPENSHIFT_APP_DOMAIN=${appurl#*.}
    keycloak_install
    backstage_install
}

while getopts "rd" flag
do
    case "${flag}" in
        r) 
            delete
            ;;
        d) 
            delete
            exit 0
            ;;
               esac
done

install
