# Does Railway fit a small app with a persistent graph that sleeps when idle?

Research for issue #92, part of map #87. Facts were checked on 2026-11-10 against Railway's and Anthropic's documentation. Jac's own deployment and storage support is covered by ticket #91 and is not repeated here.

## Short answer

Railway meets every requirement in the ticket, with two soft spots.

- A service can sleep when idle and keep a volume (a persistent disk that survives restarts). The single-writer graph matches Railway's rule that a service with a volume runs as one instance.
- A service with no public domain is reachable only from other services in the same project, so the app can sit behind a sign-in proxy service.
- The realistic cost is the Hobby plan's fixed 5 US dollars a month. That fee includes 5 dollars of usage, and this app running all day, every day is estimated at about 3 to 4 dollars of usage. Sleeping therefore does not lower the bill on Hobby; it only matters on the Free plan or if usage grows past 5 dollars.
- Soft spot 1: a sleeping service must start accepting traffic within about 10 seconds of the request that wakes it, or Railway answers that request with a 502 error. The app's start time in a container has not been measured.
- Soft spot 2: Railway staff describe sleeping as unsuited to production, and a service left asleep for a long time may need a redeploy to come back.

Because sleeping saves nothing on Hobby and carries both soft spots, running the app always-on is a real option at the same price. No comparable platform is needed on the documented facts. Fly.io is the closest alternative if the wake behaviour proves unacceptable in a test.

## Terms

- **Service**: one deployed container in a Railway project.
- **Serverless**: Railway's name for sleeping an idle service (it was called App Sleeping). The container is stopped and started again on the next request. It is not a functions product.
- **Cold start**: the delay while a sleeping service's container starts and the app becomes ready.
- **Volume**: a persistent disk mounted into one service.
- **Private network**: a network that only the services of one project environment can use, with names of the form `<service>.railway.internal`.
- **Connector**: a remote MCP server that claude.ai calls from Anthropic's cloud.

## Facts

### Sleeping and waking

- Railway treats a service as inactive after 5 minutes with no outbound packets. Inactivity is sampled, so a service sleeps 5 to 10 minutes after its last outbound traffic. A Railway guide gives the figure as 10 minutes. Sources: https://docs.railway.com/deployments/serverless and https://railway.com/guides/cut-idle-costs-serverless
- Any outbound packet counts as activity: database connections, telemetry, NTP (clock sync), calls to other services over the private network, and the responses to inbound requests. An app that polls anything while idle never sleeps. Source: https://docs.railway.com/deployments/serverless
- A sleeping service wakes on traffic from the internet or from another service in the same project over the private network. Source: https://docs.railway.com/deployments/serverless
- The setting applies when a container is created, so turning it on needs a redeploy. Source: same page.
- The documentation says the first request to a sleeping service is delayed and "may return a 502 Bad Gateway response". The guide says clients should retry. Sources: same two pages.
- A Railway employee stated in November 2024, and again in February 2025, that a waking app has up to 10 seconds to start accepting traffic; past that Railway cancels the request and returns its 502 page. This limit is not in the documentation. Sources: https://station.railway.com/questions/service-not-waking-from-sleep-http-502-3a964932 and https://station.railway.com/questions/502-error-during-cold-boot-3aac9997
- In March 2026 a bug made the proxy return 502 before a waking container was ready, even for apps that start in 2 to 3 seconds. Railway fixed it within a week; services needed a redeploy to pick up the fix. Source: https://station.railway.com/questions/serverless-deployment-returns-502-while-deeb34e5
- Sleeping services "still consume a slot" and the documentation says that in rare cases a rebuild may be needed to bring one back. In 2024 a Railway employee explained one such case: images were kept for two weeks from the last deploy, so a service asleep longer than that could fail to wake. The same employee advised against sleeping production services. Sources: https://docs.railway.com/deployments/serverless and https://station.railway.com/questions/service-not-waking-from-sleep-http-502-3a964932
- Sleeping stops compute charges: a sleeping service accrues no CPU or memory cost. Network egress is still billed. Source: https://railway.com/guides/cut-idle-costs-serverless
- Memory is freed on sleep, so anything held only in memory is lost; data on a volume is kept. Sources: https://station.railway.com/questions/does-a-sleeping-service-still-consume-ra-39276629 (community answer) and https://railway.com/guides/jupyter-server-team (Railway guide stating that files on an attached volume survive sleep and wake).

### Volumes

- Each service can have one volume. Source: https://docs.railway.com/reference/volumes
- Replicas (extra copies of a service) cannot be used with a volume, so a service with a volume is always one instance. This suits a single-writer graph store. Source: same page.
- Redeploying a service that has a volume causes a brief outage, even with a health check, because two deployments cannot mount the volume at once. Source: same page.
- Default volume size is 0.5 GB on Free and Trial, 5 GB on Hobby and 50 GB on Pro. Volumes can grow but not shrink. Volumes per project: 1 on Free, 3 on Trial, 10 on Hobby, 20 on Pro. Source: same page.
- A volume is mounted when the container starts, not during the build or the pre-deploy command. Files written to the mount path at build time do not reach the volume. A catalogue stored on the volume must therefore be built at start-up or by the running app; a catalogue baked into the image must live outside the mount path. Source: https://docs.railway.com/volumes
- Images that run as a non-root user can hit permission errors on the volume; setting `RAILWAY_RUN_UID=0` is the documented fix. Source: https://docs.railway.com/reference/volumes
- Backups can be manual or scheduled: daily (kept 6 days), weekly (kept 27 days) and monthly (kept 89 days), and more than one schedule can be active. A restore mounts a new volume from the backup at the same path, keeps the old volume unmounted, and redeploys the service. A backup can only be restored into the same project and environment. Backups are billed at the volume rate for the data unique to each backup. Wiping a volume deletes its backups. Source: https://docs.railway.com/reference/backups
- A deleted volume can be restored for 48 hours through an emailed link. Source: https://docs.railway.com/reference/volumes
- Volume files can be fetched from outside with `railway volume browse`, `railway volume files`, or sftp/scp through the attached service, which gives a way to take a copy off Railway. Source: same page.
- Sizes measured in the owner's local checkout on 2026-11-10: the saved graph is about 2 MB (`.jac/data`), the built catalogue is 75 MB (`data/catalog.sqlite`), and its downloads are 32 MB (`~/.cache/knowledge-pool/`). All of it fits in the Free plan's 0.5 GB with room to spare.

### Networking

- Services in one project environment reach each other at `http://<service>.railway.internal:<port>` over encrypted WireGuard tunnels. No setup is needed. Environments created after 16 October 2025 resolve these names to IPv4 and IPv6; older ones are IPv6 only. Source: https://docs.railway.com/networking/private-networking/how-it-works
- The private network is isolated per environment and per project, and it is not available during the build. Source: same page.
- A service is exposed to the internet by generating a Railway domain or adding a custom domain in its settings. Railway's hardening guide tells users to delete the public domain from internal services and point callers at the internal name, leaving only user-facing services public. So the app can run with no public domain behind a public proxy service that checks identity and forwards requests privately. Sources: https://docs.railway.com/reference/public-networking and https://railway.com/guides/lock-down-production-project
- Private names work only between services; a browser cannot use them. Source: https://docs.railway.com/networking/private-networking
- Public traffic is HTTPS with certificates issued by Railway, over HTTP/1.1 or HTTP/2. A request may run up to 15 minutes while data flows and is closed after 5 minutes with no data. Combined headers are limited to 32 KB. WebSockets are supported. Source: https://docs.railway.com/networking/public-networking/specs-and-limits
- A proxy in front of a sleeping app interacts with sleeping in two ways. A request from the proxy over the private network wakes the app. And if the proxy itself sends anything to the app while idle (health checks, kept-open connections), neither service sleeps. Source: https://docs.railway.com/deployments/serverless

### A claude.ai connector call to a sleeping service

- claude.ai and Claude Desktop allow 240 seconds per tool call and about 150,000 characters per tool result. Claude Code's timeout is configurable. Source: https://claude.com/docs/connectors/building
- claude.ai connects from Anthropic's cloud over Streamable HTTP (the MCP transport for remote servers). Source: same page.
- The 240-second limit is far longer than a container start, so the connector timeout is not the constraint. The constraint is Railway's side: if the app is not accepting traffic within about 10 seconds, the waking call gets a 502 instead of waiting.
- A response to an inbound request counts as outbound traffic. A connector that holds a stream open to the service would therefore keep it awake. Source for the traffic rule: https://docs.railway.com/deployments/serverless

### Cost

- Plans: Free is 0 dollars with 1 dollar of usage credit a month; Trial is a one-time 5 dollar credit that expires after 30 days; Hobby is 5 dollars a month and includes 5 dollars of usage; Pro is 20 dollars a month and includes 20 dollars of usage. Included usage does not carry over. On Hobby, 3 dollars of usage bills 5 dollars and 7 dollars of usage bills 7 dollars. Sources: https://docs.railway.com/reference/pricing/plans and https://docs.railway.com/reference/pricing/free-trial
- Rates: memory 10 dollars per GB per month, CPU 20 dollars per vCPU per month, volume 0.15 dollars per GB per month, egress 0.05 dollars per GB, all metered by the minute on actual use. Builds are free. Source: https://docs.railway.com/reference/pricing/plans
- Per-service limits: Free allows 0.5 GB of memory, 1 vCPU and a 0.5 GB volume; Hobby allows 48 GB of memory, 48 vCPU and a 5 GB volume. Source: same page.
- Estimate for this app, always on, on Hobby. One local instance of the MCP server with the web app was using 221 MB of memory after 8 minutes of running (measured with `ps` on the owner's machine on 2026-11-10; not a container measurement). At that size memory costs about 2.20 dollars a month. Idle CPU for one Python process is assumed to be 0.01 to 0.05 vCPU, which is 0.20 to 1.00 dollars. A 1 GB volume is 0.15 dollars. Egress for a few users is cents. A small sign-in proxy service would add roughly 0.50 to 1.00 dollars. The total is about 3 to 4.50 dollars of usage, inside the 5 dollars the Hobby fee already includes. The bill is 5 dollars a month whether or not the app sleeps.
- On the Free plan the 1 dollar of credit would pay for roughly 40 percent of a month of this app's memory, so Free could work only with sleeping, only with one volume in the project, and with under 0.5 GB of memory. What happens when the credit runs out mid-month was not found in the documentation; on paid plans, hitting a usage limit stops the services. Source: https://docs.railway.com/reference/pricing/faqs
- A hard usage limit can be set so that services stop instead of overspending. Source: same page.

### If Railway's wake behaviour fails a test

Railway fails no requirement on paper, so alternatives are named only for the one point that could fail in practice. On Fly.io, the platform's proxy starts a stopped machine when a request arrives and routes the request to it, machines with volumes can be stopped, CPU and memory are not billed while stopped, and a volume is billed for its full size whether or not its machine runs. Whether Fly holds the waking request without an error was not confirmed from the page read. Source: https://docs.fly.io/launch/autostop-autostart

## Not confirmed

- How long this app takes to start in a Railway container. This decides whether a waking request succeeds or gets a 502, and it needs a measurement.
- Whether the 10-second window is still the current figure. It comes from staff forum posts in 2024 and 2025, not from the documentation.
- Whether the 10-second window applies when the wake comes over the private network from a proxy service, rather than from the internet.
- Whether claude.ai retries a connector call that receives a 502. Anthropic's page does not say.
- Whether the two-week image retention for sleeping services still applies. The documentation only says a rebuild may be needed in rare cases.
- Whether a volume is billed while its service sleeps. The pricing pages bill volumes per GB per minute and state no exception, so the working assumption is yes; at this size it is cents.
- Which plans include Serverless and volume backups. Neither page names a plan. The Trial page says Trial has the same features as Hobby.
- Whether one service can publish two ports through two domains. The app serves the web UI and MCP in one process; the page that covers target ports was not readable in this session.
- Whether the Free plan allows a custom domain and how it behaves when its credit runs out.
- The memory and CPU figures in the cost estimate. Memory is one local reading; CPU is an assumption.
