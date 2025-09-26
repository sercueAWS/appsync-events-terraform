# Appsync Events POC for Smowltech (Terraform)
Terraform module to create and deploy Appsync websocket API endpoint and Lambda authorizer for Smowl.

## Components
- Appsync event API endpoint (HTTP and websocket)
- Cloudwatch logs
- Lambda authorizer setup for the API endpoint
- Lambda function (*auth*) to authorize connect, subscribe and publish operations (https://docs.aws.amazon.com/appsync/latest/eventapi/configure-event-api-auth.html)
- Lambda function (*ds*) triggered on every event received by Appsync (https://docs.aws.amazon.com/appsync/latest/eventapi/direct-lambda-integrations.html)
- IAM roles and permissions for Lambdas, Appsync and Cloudwatch

