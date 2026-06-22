#!/bin/sh
sed "s/\${LITELLM_MASTER_KEY}/${LITELLM_MASTER_KEY}/g" /etc/prometheus/prometheus.yml > /tmp/prometheus.yml
exec prometheus --config.file=/tmp/prometheus.yml --storage.tsdb.path=/prometheus --web.enable-lifecycle
