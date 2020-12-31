SHELL = bash
CFLAGS := -O3 -g -march=native
FINGERPRINT := $(shell ./shishua -b 256 2>/dev/null | ./fingerprint.sh)
TARGETS := scalar sse2 ssse3 avx2 neon
SHISHUAS :=  shishua shishua-half \
             $(addprefix shishua-,$(TARGETS)) \
             $(addprefix shishua-half-,$(TARGETS))
PRNGS := shishua shishua-half chacha8 xoshiro256plusx8 xoshiro256plus romu wyrand lehmer128 rc4
# Should match header names (aside from -scalar and -ssse3)
IMPLS := $(SHISHUAS) chacha8 xoshiro256plusx8 xoshiro256plus romu wyrand lehmer128 rc4
TESTS := $(addprefix test-,$(TARGETS))
SSH_KEY = ~/.ssh/id_ed25519

# We need second expansions.
.SECONDEXPANSION:

##
## Target rules.
##

# Replace pseudo target names with the real names.
# The HEADER preproc variable is used in prng.c.
fix_target = $(subst -scalar,,$(subst -ssse3,-sse2,$(1)))
$(IMPLS): HEADER = $(call fix_target,$@).h
$(TESTS): SUFFIX = $(patsubst test%,%.h,$(call fix_target,$@))

# Force SSE2, disable SSE3
%-sse2: CFLAGS += -msse2 -mno-sse3 -mno-ssse3
%-ssse3: CFLAGS += -mssse3
# -mtune=haswell disables GCC load/store splitting
%-avx2: CFLAGS += -mavx2 -mtune=haswell
xoshiro256plusx8: CFLAGS += -fdisable-tree-cunrolli
# force scalar target
%-scalar: CFLAGS += -DSHISHUA_TARGET=SHISHUA_TARGET_SCALAR

##
## Recipes.
##
default: shishua shishua-half

# e.g. make neon -> make shishua-neon shishua-half-neon
$(TARGETS): %: shishua-% shishua-half-%

$(IMPLS): $$(HEADER) prng.c
	$(CC) $(CFLAGS) -DHEADER='"$(HEADER)"' prng.c -o $@

$(TESTS): test-vectors.c test-vectors.h shishua$$(SUFFIX) shishua-half$$(SUFFIX)
	$(CC) $(CFLAGS) -DHEADER='"shishua$(SUFFIX)"' -DHEADER_HALF='"shishua-half$(SUFFIX)"' $< -o $@
	./$@

intertwine: intertwine.c
	$(CC) $(CFLAGS) -o $@ $<

##
## Quality testing.
##

/usr/local/bin/RNG_test:
	mkdir PractRand
	curl -Ls 'https://downloads.sourceforge.net/project/pracrand/PractRand-pre0.95.zip' >PractRand/PractRand.zip
	cd PractRand; \
	  unzip PractRand.zip; \
	  g++ -c src/*.cpp src/RNGs/*.cpp src/RNGs/other/*.cpp -O3 -Iinclude -pthread; \
	  ar rcs libPractRand.a *.o; \
	  g++ -o RNG_test tools/RNG_test.cpp libPractRand.a -O3 -Iinclude -pthread; \
	  g++ -o RNG_benchmark tools/RNG_benchmark.cpp libPractRand.a -O3 -Iinclude -pthread; \
	  g++ -o RNG_output tools/RNG_output.cpp libPractRand.a -O3 -Iinclude -pthread
	sudo mv PractRand/RNG_{test,benchmark,output} /usr/local/bin
	rm -rf PractRand

/usr/local/bin/testu01: testu01.c
	curl -sO 'http://simul.iro.umontreal.ca/testu01/TestU01.zip'
	unzip TestU01.zip
	mv TestU01-*/ TestU01
	cd TestU01; \
	  ./configure --prefix="$$(dirname $$(pwd))"; \
	  make; make install
	gcc -std=c99 -Wall -O3 -o testu01 testu01.c -Iinclude -Llib -ltestu01 -lprobdist -lmylib -lm
	sudo mv testu01 /usr/local/bin
	rm -rf TestU01*

test: test/perf-$(FINGERPRINT) test/PractRand-$(FINGERPRINT) test/BigCrush-$(FINGERPRINT)

test/PractRand-$(FINGERPRINT): /usr/local/bin/RNG_test shishua
	@mkdir -p test
	@echo "Date $$(date)" | tee test/PractRand-$(FINGERPRINT)
	@echo "PRNG fingerprint: $(FINGERPRINT)" | tee -a test/PractRand-$(FINGERPRINT)
	./shishua | RNG_test stdin64 | tee -a test/PractRand-$(FINGERPRINT)

test/BigCrush-$(FINGERPRINT): /usr/local/bin/testu01 shishua
	@mkdir -p test
	@echo "Date $$(date)" | tee test/BigCrush-$(FINGERPRINT)
	@echo "PRNG fingerprint: $(FINGERPRINT)" | tee -a test/BigCrush-$(FINGERPRINT)
	./shishua | testu01 --big | tee -a test/BigCrush-$(FINGERPRINT)

test/benchmark-seed: $(PRNGS) intertwine
	@mkdir -p test
	@echo "Date $$(date)" | tee $@
	for prng in $(PRNGS); do \
	  echo "$$prng fingerprint: $$(./$$prng | ./fingerprint.sh)" | tee -a $@; \
	  ./intertwine <(./$$prng -s 1) <(./$$prng -s 2) \
	               <(./$$prng -s 4) <(./$$prng -s 8) \
	               <(./$$prng -s 10) <(./$$prng -s 20) \
	               <(./$$prng -s 40) <(./$$prng -s 80) \
	    | RNG_test stdin -tlmax 1M -tlmin 1K -te 1 -tf 2 | tee -a $@; \
	done

##
## Performance testing.
##

# This must be performed with no other processes running.

test/perf-$(FINGERPRINT): shishua
	@mkdir -p test
	@echo "Date $$(date)" | tee $@
	@echo "PRNG fingerprint: $(FINGERPRINT)" | tee -a $@
	./shishua --bytes 4294967296 -q 2>&1 | tee -a $@

test/benchmark-perf: $(PRNGS)
	@mkdir -p test
	@echo "Date $$(date)" | tee $@
	for prng in $(PRNGS); do \
	  ./fix-cpu-freq.sh ./$$prng --bytes 4294967296 -q 2>&1 | tee -a $@; \
	done

# To reach a consistent benchmark, we need a universally-reproducible system.
# GCP will do.

# Installation instructions from https://cloud.google.com/sdk/docs/downloads-apt-get
/usr/bin/gcloud:
	echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
	sudo apt-get install apt-transport-https ca-certificates gnupg
	curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
	sudo apt-get update && sudo apt-get install google-cloud-sdk
	gcloud init

# Installation instructions for Scaleway CLI (for ARM servers)
# available here: https://github.com/scaleway/scaleway-cli#linux
/usr/local/bin/scw:
	sudo curl -o /usr/local/bin/scw -L "https://github.com/scaleway/scaleway-cli/releases/download/v2.2.3/scw-2.2.3-linux-x86_64"
	sudo chmod +x /usr/local/bin/scw
	scw init

benchmark-intel: /usr/bin/gcloud
	gcloud compute instances create shishua-intel \
	  --machine-type=n2-standard-2 \
	  --maintenance-policy=TERMINATE \
	  --zone=us-central1-f \
	  --image-project=ubuntu-os-cloud --image-family=ubuntu-2004-lts
	tar cJf shishua.tar.xz $$(git ls-files)
	while ! gcloud compute ssh shishua-intel --ssh-key-file=$(SSH_KEY) --zone=us-central1-f -- 'echo sshd started.'; do echo Awaiting sshd…; done
	gcloud compute scp ./shishua.tar.xz shishua-intel:~ --ssh-key-file=$(SSH_KEY) --zone=us-central1-f
	rm shishua.tar.xz
	gcloud compute ssh shishua-intel --ssh-key-file=$(SSH_KEY) --zone=us-central1-f -- 'tar xJf shishua.tar.xz && ./gcp-perf.sh'
	gcloud compute instances delete shishua-intel --zone=us-central1-f

# We must use us-central1 to have access to N2D, with the new AMD CPUs.
benchmark-amd: /usr/bin/gcloud
	gcloud compute instances create shishua-amd \
	  --machine-type=n2d-standard-2 \
	  --maintenance-policy=TERMINATE \
	  --zone=us-central1-f \
	  --image-project=ubuntu-os-cloud --image-family=ubuntu-2004-lts
	tar cJf shishua.tar.xz $$(git ls-files)
	while ! gcloud compute ssh shishua-amd --ssh-key-file=$(SSH_KEY) --zone=us-central1-f -- 'echo sshd started.'; do echo Awaiting sshd…; done
	gcloud compute scp ./shishua.tar.xz shishua-amd:~ --ssh-key-file=$(SSH_KEY) --zone=us-central1-f
	rm shishua.tar.xz
	gcloud compute ssh shishua-amd --ssh-key-file=$(SSH_KEY) --zone=us-central1-f -- 'tar xJf shishua.tar.xz && ./gcp-perf.sh'
	gcloud compute instances delete shishua-amd --zone=us-central1-f

benchmark-arm: /usr/local/bin/scw
	@set -x; srvconf=$$(scw instance server create name=shishua-arm type=C1 stopped=true boot-type=bootscript image=ubuntu_bionic zone=fr-par-1); \
	srvid=$$(echo "$$srvconf" | grep '^ID' | awk '{print $$2}'); \
	srvip=$$(echo "$$srvconf" | grep '^PublicIP.Address' | awk '{print $$2}'); \
	scw instance server start "$$srvid" --wait; \
	tar cJf shishua.tar.xz $$(git ls-files); \
	while ! scw instance server ssh "$$srvid" command='echo sshd started.' zone=fr-par-1; \
	  do echo Awaiting sshd…; sleep 5; \
	done; \
	scp -i $(SSH_KEY) ./shishua.tar.xz root@"$$srvip:~"; \
	scw instance server ssh "$$srvid" command='tar xJf shishua.tar.xz && ./scw-perf.sh' zone=fr-par-1; \
	echo Deleting ARM server…; \
	scw instance server terminate "$$srvid" zone=fr-par-1 with-block with-ip
	rm shishua.tar.xz

clean:
	$(RM) -rf $(TESTS) $(IMPLS) intertwine

.PHONY: test clean benchmark-intel benchmark-amd benchmark-arm
