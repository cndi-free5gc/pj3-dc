.PHONY: image up upd down ue upf build test lint

.DEFAULT_GOAL := image

image:
	docker build -f Dockerfile -t pj3/free-ran-ue:latest .

up:
	docker compose -f docker-compose-dc.yaml up

upd:
	docker compose -f docker-compose-dc.yaml up -d

down:
	docker compose -f docker-compose-dc.yaml down

ue:
	docker exec -it ue bash

upf:
	docker exec -it upf bash

build:
	cd free-ran-ue && go build ./...

test:
	cd free-ran-ue && go test ./...

lint:
	cd free-ran-ue && golangci-lint run