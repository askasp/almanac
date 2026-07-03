# Almanac dev helpers.  Run `make help` for the list.
.DEFAULT_GOAL := help
.PHONY: help up down logs signal-logs qr fresh fresh-hard psql messages config errors actions retry doctor

help:            ## list commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

up:              ## build + start everything
	docker compose up -d --build

down:            ## stop (keep data)
	docker compose down

logs:            ## follow the db logs
	docker compose logs -f db

signal-logs:     ## follow the signal sidecar logs (raw envelopes)
	docker compose logs -f signal

qr:              ## fetch a fresh Signal linking QR (scan in Signal -> Linked Devices)
	@curl -s "http://localhost:8080/v1/qrcodelink?device_name=almanac" --output qr.png \
	  && echo "saved qr.png -- scan it in Signal -> Settings -> Linked Devices"

fresh:           ## wipe the DB and restart clean; KEEPS the Signal pairing
	docker compose down -v
	docker compose up -d --build
	@echo "Fresh DB. Signal link kept (./signal-data); the Almanac group is re-discovered within ~1 min."

fresh-hard:      ## wipe EVERYTHING incl. the Signal pairing (you'll re-scan the QR)
	docker compose down -v
	rm -rf signal-data
	docker compose up -d --build
	@echo "All wiped. Re-pair Signal:  make qr"

psql:            ## open a psql shell
	docker compose exec db psql -U almanac -d almanac

messages:        ## show the 10 most recent messages
	docker compose exec db psql -U almanac -d almanac -c \
	  "SELECT id,status,role,left(content,50) FROM messages ORDER BY id DESC LIMIT 10;"

config:          ## show the live channel / signal / llm config
	docker compose exec db psql -U almanac -d almanac -c \
	  "SELECT key,value FROM config WHERE key='channel' OR key LIKE 'signal%' OR key LIKE 'llm%' ORDER BY key;"

errors:          ## show recent failures + the REAL error text (not the generic 'Sorry')
	docker compose exec db psql -U almanac -d almanac -c \
	  "SELECT id, attempts, status, left(content,40) AS msg, left(error,400) AS error \
	   FROM messages WHERE error IS NOT NULL ORDER BY id DESC LIMIT 10;"

actions:         ## show recent tool calls + results (which tool failed, and why)
	docker compose exec db psql -U almanac -d almanac -c \
	  "SELECT id, tool_name, left(result,140) AS result FROM actions ORDER BY id DESC LIMIT 15;"

retry:           ## re-queue failed/stuck messages after you fix config (no need to re-send)
	docker compose exec db psql -U almanac -d almanac -c \
	  "UPDATE messages SET status='pending', attempts=0, error=NULL \
	   WHERE role='user' AND status IN ('error','processing');"

doctor:          ## ONE-SHOT health check — paste this output when something's wrong
	@echo "═════ 0. containers (want db = Up/healthy, NOT Restarting/Exited) ═════"
	-@docker compose ps
	@echo "═════ 1. bootstrap  (want: [almanac] bootstrap complete.) ═════"
	-@docker compose logs db --tail 300 2>&1 | grep "almanac\]" || echo "  !! no bootstrap line in last 300 log lines — init didn't run, or DB unhealthy"
	@echo "═════ 2. config     (want: llm_base_url=openrouter, signal_number filled) ═════"
	-@docker compose exec -T db psql -U almanac -d almanac -c \
	  "SELECT key,value FROM config WHERE key='channel' OR key LIKE 'signal%' OR key LIKE 'llm%' ORDER BY key;"
	@echo "═════ 3. secrets    (want: key_set=t, llm_api_key preview 'sk-or-') ═════"
	-@docker compose exec -T db psql -U almanac -d almanac -c \
	  "SELECT secret_key() IS NOT NULL AS key_set; SELECT name, left(get_secret(name),6) AS preview FROM secrets ORDER BY name;"
	@echo "═════ 4. errors     (the REAL message behind 'Sorry — I hit an error') ═════"
	-@docker compose exec -T db psql -U almanac -d almanac -c \
	  "SELECT id, attempts, status, left(error,300) AS error FROM messages WHERE error IS NOT NULL ORDER BY id DESC LIMIT 5;"
	@echo "═════ 5. tool calls (which tool ran, and its result) ═════"
	-@docker compose exec -T db psql -U almanac -d almanac -c \
	  "SELECT id, tool_name, left(result,120) AS result FROM actions ORDER BY id DESC LIMIT 8;"
