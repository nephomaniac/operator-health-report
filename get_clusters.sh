ocm get clusters --parameter search="hypershift.enabled='false' and managed='true' and state='ready' and product.id='rosa'" | jq -r '["ID", "NAME", "VERSION", "STATUS", "PRIV", "CREATED"], ["--", "----", "-------", "------", "----", "-------"], (.items[]| [.id, .name, .openshift_version, .status.state, .aws.private_link, .creation_timestamp]) | @tsv' | column -ts $'\t'

ocm get clusters --parameter search="managed='true' and state='ready' and product.id='osd'" | jq -r '["ID", "NAME", "VERSION", "STATUS", "PRIV", "CREATED"], ["--", "----", "-------", "------", "----", "-------"], (.items[]| [.id, .name, .openshift_version, .status.state, .aws.private_link, .creation_timestamp]) | @tsv' | column -ts $'\t'

