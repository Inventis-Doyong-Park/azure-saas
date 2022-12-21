#!/bin/bash

set -u -e -o pipefail

# include script modules into current shell
source "./script/config-module.sh"
source "./script/app-reg-module.sh"
source "./script/colors-module.sh"
source "./script/log-module.sh"
source "./script/constants-module.sh"
source "./script/tenant-login-module.sh"

b2c_tenant_name="$( get-value ".deployment.azureb2c.name" )"

# login to the B2C tenant
echo "Logging into B2C tenant ${b2c_tenant_name}." \
    | log-output \
        --level info \
        --header "Azure B2C Tenant Login"

log-into-b2c "${b2c_tenant_name}" \
    || echo "Azure B2C tenant login failed." \
        | log-output \
            --level error \
            --header "Critical error" \
            | exit 1

echo "Azure B2C tenant login successful." \
    | log-output \
        --level success

echo "Adding app registrations to Azure B2C tenant." \
    | log-output \
        --level info \
        --header "Azure B2C App Registrations"

# create the app registrations
declare -i scopes_length
declare -i permissions_length
declare -i i

b2c_name="$( get-value ".deployment.azureb2c.name" )"
prefix="$( get-value ".initConfig.naming.solutionPrefix" )"
postfix="$( get-value ".deployment.postfix" )"
solution_name="$( get-value ".initConfig.naming.solutionName" )"
app_id_uri="https://${b2c_name}/${prefix}-${solution_name}-${postfix}"

# read each item in the JSON array to an item in the Bash array
readarray -t app_reg_array < <( jq -c '.appRegistrations[]' "${CONFIG_FILE}")

# counter for iterations on Bash array
i=1

# iterate through the Bash array
for app in "${app_reg_array[@]}"; do
    app_name=$( jq -r '.name'                           <<< "${app}" )
    app_id=$( jq -r '.appId'                            <<< "${app}" )
    has_cert=$( jq -r '.certificate'                    <<< "${app}" )
    redirect_uri=$( jq -r '.redirectUri'                <<< "${app}" )
    permissions=$( jq -r '.permissions'                 <<< "${app}" )
    permissions_length=$( jq '.permissions | length'    <<< "${app}" )
    scopes=$( jq -r '.scopes'                           <<< "${app}" )
    scopes_length=$( jq '.scopes | length'              <<< "${app}" )
    
    display_name="${prefix}-${app_name}"

    echo "Provisioning app registration for: ${display_name}..." \
        | log-output \
            --level info \
            --header "${display_name}"

    if [[ -n "${app_id}" \
        && ! "${redirect_uri}" == null \
        && ! "${redirect_uri}" == "null" ]]; then

        if app-exist "${app_id}"; then
        
            echo "App registration for ${app_name} already exist." \
                | log-output --level info

            continue
        fi
    fi
    
    if [[ -n "${redirect_uri}" \
        && ! "${redirect_uri}" == null \
        && ! "${redirect_uri}" == "null" ]]; then
    
        # create app with redirect uri
        echo "Creating app with redirect_uri: ${redirect_uri}" | log-output --level info 
        
        app_json="$( az ad app create \
            --display-name "${display_name}" \
            --web-redirect-uris "${redirect_uri}" \
            --only-show-errors \
            --query "{Id:id, AppId:appId}" \
            || echo "Failed to create app with redirect uri: ${redirect_uri}" \
                | log-output \
                    --level error \
                    --header "Critical error" \
                    | exit 1 )" || exit 1
    else
    
        # create app registration without redirect uri
        echo "Creating app registration without redirect uri" | log-output --level info
        app_json="$( az ad app create \
            --display-name "${display_name}" \
            --only-show-errors \
            --query "{Id:id, AppId:appId}" \
            || echo "Failed to create app without redirect uri" \
                | log-output \
                    --level error \
                    --header "Critical error" \
                    | exit 1 )" || exit 1
    fi

    echo "App created: ${app_json}" | log-output --level success

    obj_id=$( jq -r '.Id' <<< "${app_json}" )
    app_id=$( jq -r '.AppId' <<< "${app_json}" )

    # add appId to config
    put-app-id "${app_name}" "${app_id}"

    # add identifier uri when scopes are present
    if [[ (( $scopes_length -gt 0)) ]]; then
        echo -e "Adding identifier uri for: ${prefix}-${app_name}..." | log-output
        az ad app update\
            --id "${app_id}" \
            --only-show-errors \
            --identifier-uris "${app_id_uri}" \
            || echo "Failed to update app $app_name, ${app_id}: $?" \
                | log-output \
                    --level error \
                    --header "Critical error" \
                    | exit 1
            
        echo "Identifier added: ${app_id_uri}" | log-output
    fi

    # add certificate to app registration if cert is true
    if [[ "${has_cert}" == true || "${has_cert}" == "true" ]]; then
        echo "Adding public key certificate for: ${prefix}-${app_name}..." \
            | log-output --level info

        cert_path=$( jq -r '.publicKeyPath' <<< "${app}" )

        az ad app credential reset \
            --id "${obj_id}" \
            --cert "@${cert_path}" \
            --only-show-errors \
            | log-output \
                --level info \
            || echo "Failed to add certificate to app $app_name, ${app_id}: $?" \
                | log-output \
                    --level error \
                    --header "Critical error" \
                    | exit 1

        echo "Certificate added for: ${prefix}-${app_name}" | log-output --level success
    fi

    # add permissions to app registration if permissions is true
    if [[ (( $scopes_length -gt 0)) ]]; then

        echo "Adding permissions for: ${prefix}-${app_name}..." \
            | log-output --level info

        echo "Adding ${scopes_length} scopes: ${scopes}" \
            | log-output --level info

        add-permission-scopes "${obj_id}" "${app_name}" "${scopes}"

        echo "Permissions added for: ${prefix}-${app_name}" \
            | log-output --level success
    fi

    # add ressource 
    if [[ (( $permissions_length -gt 0)) ]]; then
        echo "Adding required resource access for: ${prefix}-${app_name}..." \
            | log-output --level info

        add-required-resource-access "${permissions}" "${app_id}"
            
        echo "Required resource access added for: ${prefix}-${app_name}" \
            | log-output --level success
    fi

    # for testing purposes only
    # if [[ (( $i == 2 )) ]]; then
    #     exit 1
    # fi

    ((++i))
done