.PHONY: preflight up setup produce verify logs down clean

preflight: up setup produce verify

up:
	docker compose up -d --build minio mc-init iceberg-rest kafka kafka-connect

setup:
	./scripts/setup.sh

produce:
	./scripts/produce.sh 300

verify:
	./scripts/verify.sh

logs:
	docker compose logs -f

down:
	docker compose down

clean:
	docker compose down -v --remove-orphans
	rm -rf out
