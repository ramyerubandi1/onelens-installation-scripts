#!/bin/bash
helm repo update
helm upgrade onelens-agent onelens/onelens-agent \
  --version=0.1.1-beta.3 \
  --namespace onelens-agent \
  --reuse-values 