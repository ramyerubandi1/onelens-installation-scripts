# onelens-installation-scripts

#### Steps to Build the Docker Images: 
docker buildx build --platform linux/amd64,linux/arm64 -t public.ecr.aws/w7k6q5m9/onelens-deployer:latest --push .


#### Helm package move the file to onelens-charts repo 
helm package  ./onelensdeployer  - this created a tgz file - onelensdeployer-0.1.0.tgz

#### Copy the onelensdeployer-0.1.0.tgz to onelens-chart 
cp -r onelensdeployer-0.1.0.tgz <path_to_repo>/onelens-charts

