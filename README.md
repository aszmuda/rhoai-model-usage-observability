# External Metering Simulator

This project contains a Go HTTP simulator that accepts metering CloudEvents and writes each accepted event as a structured JSON log line. OpenShift logging forwards those container logs to the LokiStack usage tenant. An optional Perses dashboard displays token and request details from the events.

## Project layout

| Path | Contents |
| --- | --- |
| `external-metering/simulator/` | Go service, container image, and OpenShift resources |
| `external-metering/payload-processing-plugins.yaml` | Client plugin configuration and simulator egress policy |
| `deploy/logging-operator/` | Logging Operator subscription |
| `deploy/perses/` | Usage dashboard and Loki datasource |
| `deploy/console/` | Perses console integration |
| `scripts/simulator.sh` | Build, deploy, dashboard, inspect, test, and run commands |

## Requirements

| Task | Requirements |
| --- | --- |
| OpenShift build and deployment | Bash, oc logged in to the intended cluster, permission to create the resources below, and a working internal image registry |
| Simulator and log forwarding | LokiStack usage in redhat-ods-monitoring; payload-pre-processing and payload-processing Deployments in openshift-ingress |
| Local test or run | Go 1.25+ |
| HTTP smoke check | curl and a running simulator, either local or through port-forward |
| Console dashboard | COO/Perses with Loki log and time-series plugins |

Check the active cluster before running cluster commands:

    oc config current-context
    oc whoami

The deploy command installs the Logging Operator from channel stable-6.7 if it is missing. The LokiStack and COO/Perses installation are prerequisites and are not installed by this project. OpenShift must be able to pull the container base image.

## Build the simulator image

    ./scripts/simulator.sh build

This creates or updates the external-metering namespace, ImageStream, and binary BuildConfig, then uploads the local source to OpenShift for an image build. The upload contains the Dockerfile, Go module, and source directories. It does not require local Go or install the Logging Operator. This command builds the image but does not deploy the running simulator or collector.

Run build again after changing the Go source. If a simulator Deployment already exists, its ImageStream trigger rolls out the updated image.

## Deploy the simulator and logging

    ./scripts/simulator.sh deploy

Running the script with no command is equivalent to deploy. It checks for the required LokiStack and client Deployments, then:

1. Installs the Logging Operator if it is missing and waits for the operator, ClusterLogForwarder CRD, and collection role.
2. Applies the build resources and reuses the existing simulator image when available. If there is no image, it builds the local source in OpenShift.
3. Applies the simulator Deployment and Service, dedicated ClusterLogForwarder, service account, RBAC, and service CA resources.
4. Applies the payload processor plugin ConfigMap and egress NetworkPolicy, then restarts and waits for both client Deployments.

The client plugin sends CloudEvents to the simulator service in the external-metering namespace. The plugin manifest is applied as maintained here, so incorporate any cluster-specific plugin configuration into that file before deploying. Restarting the client Deployments makes them load the updated configuration.

To inspect the deployment and submit a sample event:

    ./scripts/simulator.sh status
    ./scripts/simulator.sh port-forward

In another terminal:

    ./scripts/simulator.sh smoke

Port-forward uses localhost port 8080 by default. The smoke command checks readiness and entitlement access, then posts a sample event with a fresh ID. It reports 150 prompt, 80 completion, and 230 total tokens. Find the printed ID in Loki to confirm that the event was collected; an HTTP response alone only confirms that the simulator accepted and logged it.

Use another local port if needed:

    ./scripts/simulator.sh port-forward --port 18080

In another terminal:

    ./scripts/simulator.sh smoke --url http://127.0.0.1:18080

## Logging and dashboard

The dedicated ClusterLogForwarder selects only the simulator container and sends its logs to LokiStack usage in redhat-ods-monitoring over TLS. Its service account has the permissions required to collect application logs and write to the Loki tenant. The Logging Operator manages the collector DaemonSet.

With LokiStack usage and COO/Perses available, install the console integration and dashboard:

    ./scripts/simulator.sh dashboard

The command checks for LokiStack usage, the existing usage-gateway-ca-bundle ConfigMap, and the Perses resource types. It enables Perses on an existing monitoring UIPlugin with a merge patch that preserves its other settings; if the UIPlugin does not exist, it applies the supplied console resource. If a configuration owner manages the UIPlugin, record the Perses setting there as well. The command then applies the dashboard and datasource.

The datasource trusts the gateway with the existing usage-gateway-ca-bundle ConfigMap in redhat-ods-monitoring, using its service-ca.crt key. Open Observe → Dashboards (Perses), select redhat-ods-monitoring, and open Usage as an administrator. The dashboard's User, Model, Subscription, and Provider filters refer to fields carried in the metering events.

## Local development

Run the existing Go unit tests or start the simulator locally:

    ./scripts/simulator.sh test
    ./scripts/simulator.sh run

In another terminal, use the smoke command shown above. The simulator listens on port 8080 by default. The script accepts --go PATH for a Go executable outside PATH, --oc PATH for an alternate OpenShift CLI, --url URL for smoke checks, and --port PORT for local run or port-forward. GO, OC, and BASE_URL are supported as defaults for those options. When running the Go service directly, PORT sets the listen port and LISTEN_ADDR can set the full listen address.

## API behavior

- GET /healthz and GET /readyz return 200 when the process is available.
- GET /api/v1/customers/{id}/entitlements/{key}/value returns an always-allowed entitlement response.
- POST /api/v1/events accepts a JSON CloudEvent up to 64 KiB and returns 204 after writing one structured event to stdout.

Invalid events return 400, oversized requests return 413, and unsupported content types return 415. The simulator does not calculate quotas or persist events itself. A 204 response confirms stdout logging; Loki persistence depends on the collector and cluster logging path.

## Tear down

    ./scripts/simulator.sh teardown

Teardown removes the external-metering namespace, including the simulator, build resources, image, collector, and resources in that namespace. It also removes the simulator's cluster-scoped collector permissions.

It leaves the shared Logging Operator, LokiStack, console settings, dashboard resources, and payload processor configuration in place. Teardown does not restore a previous plugin ConfigMap or stop the client Deployments from using the simulator. To stop sending events, restore the shared plugin configuration through its owner and restart both client Deployments.
