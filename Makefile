# Almanac dev helpers.  Run `make help` for the list.
.DEFAULT_GOAL := help
.PHONY: help up down logs signal-logs qr fresh fresh-hard psql messages config

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

config:          ## show the live channel / signal config
	docker compose exec db psql -U almanac -d almanac -c \
	  "SELECT key,value FROM config WHERE key='channel' OR key LIKE 'signal%' ORDER BY key;"
