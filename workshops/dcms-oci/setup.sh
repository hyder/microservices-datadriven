#!/bin/bash
# Copyright (c) 2021 Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# Fail on error
set -eu

# Make sure this is executed and not sourced
if (return 0 2>/dev/null) ; then
  echo "ERROR: Usage './setup.sh'"
  exit 1
fi

# Environment must be setup before running this script
if test -z "$DCMS_STATE"; then
  echo "ERROR: Workshop environment not setup"
  exit 1
fi

# Get the state_store status
if ! DCMS_SS_STATUS=$(provisioning-get-status $DCMS_STATE_STORE); then
  echo "ERROR: Unable to get workshop state_store status"
  exit 1
fi

case "$DCMS_SS_STATUS" in

  applied | byo)
    # Nothing to do
    ;;

  applying)
    # Setup already running so exit
    exit 0
    ;;

  destroying-failed | destroying | destroyed)
    # Cannot setup during destroy phase
    echo "ERROR: Destroy is running and so cannot run setup"
    exit 1
    ;;

  applying-failed | new)
    # Start or restart the state_store setup
    cd $DCMS_STATE_STORE
    echo "STATE_LOG='$DCMS_LOG_DIR/state.log'" > $DCMS_STATE_STORE/input.env
    if ! provisioning-apply $MSDD_INFRA_CODE/state_store; then
      echo "ERROR: Failed to create state_store in $DCMS_STATE_STORE"
      exit 1
    fi
    ;;

esac
source $DCMS_STATE_STORE/output.env

# Start background builds
cd $DCMS_BACKGROUND_BUILDS
nohup $MSDD_WORKSHOP_CODE/$DCMS_WORKSHOP/background-builds.sh >>$DCMS_LOG_DIR/background-builds.log 2>&1 &

# Get the setup status
if ! DCMS_STATUS=$(provisioning-get-status $DCMS_STATE); then
  echo "ERROR: Unable to get workshop provisioning status"
  exit 1
fi

case "$DCMS_STATUS" in

  applied | byo)
    # Nothing to do
    exit
    ;;

  applying)
    # Nothing to do
    exit
    ;;

  destroying | destroying-failed | destroyed)
    # Cannot setup during destroy phase
    echo "ERROR: Destroy is running and so cannot run setup"
    exit 1
    ;;

  applying-failed)
    # Restart the setup
    cd $DCMS_STATE
    echo "Restarting setup.  Call 'status' to get the status of the setup"
    nohup bash -c "provisioning-apply $MSDD_WORKSHOP_CODE/$DCMS_WORKSHOP/config" >>$DCMS_LOG_DIR/setup.log 2>&1 &
    exit
    ;;

  new)
    # New setup
    ;;

esac

##### New Setup

# Register our source.env in .bash_profile
PROF=~/.bashrc
if test -f "$PROF"; then
  sed -i.bak '/microservices-datadriven/d' $PROF
fi
echo "source $MSDD_WORKSHOP_CODE/$DCMS_WORKSHOP/source.env #microservices-datadriven" >>$PROF
echo 'echo "Running workshop from folder $MSDD_WORKSHOP_CODE #microservices-datadriven"' >>$PROF

# Check that the prerequisite utils are installed
for util in oci kubectl terraform docker mvn ssh sqlplus helm; do
  exec=`which $util`
  if test -z "$exec"; then
    echo "ERROR: $util is not installed"
    return 1
  fi
done

# Check that the OCI CLI is configured
if ! test -f "$OCI_CLI_CONFIG_FILE" && ! test -f ~/.oci/config; then
  echo "ERROR: The OCI CLI is not configured"
  return 1
fi

# Run Name (random)
if ! state_done RUN_NAME; then
  state_set RUN_NAME gd`awk 'BEGIN { srand(); print int(1 + rand() * 100000000)}'`
fi

# Hard coded for now
if ! state_done DB_DEPLOYMENT; then
state_set DB_DEPLOYMENT 2DB
fi

if ! state_done DB_TYPE; then
state_set DB_TYPE ATP
fi

if ! state_done QUEUE_TYPE; then
state_set QUEUE_TYPE classicq
fi

# Identify Run Type
while ! state_done RUN_TYPE; do
  if [[ "$HOME" =~ /home/ll[0-9]{1,5}_us ]]; then
    state_set RUN_TYPE "LL"
    state_set RESERVATION_ID `grep -oP '(?<=/home/ll).*?(?=_us)' <<<"$HOME"`
    state_set USER_OCID 'NA'
    state_set USER_NAME "LL$(state_get RESERVATION_ID)-USER"
    state_set DB1_NAME "ORDER$(state_get RESERVATION_ID)"
    state_set DB2_NAME "INVENTORY$(state_get RESERVATION_ID)"
    state_set_done OKE_LIMIT_CHECK
    state_set_done ATP_LIMIT_CHECK
    state_set HOME_REGION 'NA'
  else
    # Run in your own tenancy
    state_set RUN_TYPE "OT"
    state_set DB1_NAME "$(state_get RUN_NAME)1"
    state_set DB2_NAME "$(state_get RUN_NAME)2"
  fi
done

# Tenancy OCID
while ! state_done TENANCY_OCID; do
  if ! test -z "$OCI_TENANCY"; then
    state_set TENANCY_OCID "$OCI_TENANCY"
  else
    # Get the tenancy OCID
    while true; do
      read -p "Please enter your OCI tenancy OCID: " OCI_TENANCY
      if oci iam tenancy get --tenancy-id "$OCI_TENANCY" 2>&1 >$DCMS_LOG_DIR/tenancy_ocid_err; then
        state_set TENANCY_OCID "$OCI_TENANCY"
      else
        echo "The tenancy OCID $OCI_TENANCY could not be validated.  Please retry."
        cat $DCMS_LOG_DIR/tenancy_ocid_err
      fi
    done
  fi
done

# Check OKE Limits
if ! state_done OKE_LIMIT_CHECK; then
  # Cluster Service Limit
  OKE_LIMIT=`oci limits value list --compartment-id "$(state_get TENANCY_OCID)" --service-name "container-engine" --query 'sum(data[?"name"=='"'cluster-count'"'].value)'`
  if test "$OKE_LIMIT" -lt 1; then
    echo 'The service limit for the "Container Engine" "Cluster Count" is insufficent to run this workshop.  At least 1 is required.'
    exit
  elif test "$OKE_LIMIT" -eq 1; then
    echo 'You are limited to only one OKE cluster in this tenancy.  This workshop will create one additional OKE cluster and so any other OKE clusters must be terminated.'
    if test -z "${TEST_USER_OCID-}"; then
      read -p "Please confirm that no other un-terminated OKE clusters exist in this tenancy and then hit [RETURN]? " DUMMY
    fi
  fi
  state_set_done OKE_LIMIT_CHECK
fi

# Check ATP resource availability
while ! state_done ATP_LIMIT_CHECK; do
  CHECK=1
  # ATP OCPU availability
  if test $(oci limits resource-availability get --compartment-id="$(state_get TENANCY_OCID)" --service-name "database" --limit-name "atp-ocpu-count" --query 'to_string(min([data."fractional-availability",`4.0`]))' --raw-output) != '4.0'; then
    echo 'The "Autonomous Transaction Processing OCPU Count" resource availability is insufficent to run this workshop.'
    echo '4 OCPUs are required.  Terminate some existing ATP databases and try again.'
    CHECK=0
  fi

  # ATP storage availability
  if test $(oci limits resource-availability get --compartment-id="$(state_get TENANCY_OCID)" --service-name "database" --limit-name "atp-total-storage-tb" --query 'to_string(min([data."fractional-availability",`2.0`]))' --raw-output) != '2.0'; then
    echo 'The "Autonomous Transaction Processing Total Storage (TB)" resource availability is insufficent to run this workshop.'
    echo '2 TB are required.  Terminate some existing ATP databases and try again.'
    CHECK=0
  fi

  if test $CHECK -eq 1; then
    state_set_done ATP_LIMIT_CHECK
  else
    read -p "Hit [RETURN] when you are ready to retry? " DUMMY
  fi
done

# Home Region
if ! state_done HOME_REGION; then
  state_set HOME_REGION `oci iam region-subscription list --query 'data[?"is-home-region"]."region-name" | join('\'' '\'', @)' --raw-output`
fi

# Create or validate the compartment
while ! state_done COMPARTMENT_OCID; do
  if test "$(state_get RUN_TYPE)" == 'LL'; then
    # The compartment is already created.  Ask for the OCID
    read -p "Please enter your OCI compartment's OCID: " COMPARTMENT_OCID
    if ! oci iam compartment get --compartment-id "$COMPARTMENT_OCID" 2>&1 >$DCMS_LOG_DIR/comp_ocid_err; then
      echo "ERROR: The compartment $COMPARTMENT_OCID does not exist.  Please retry."
      cat $DCMS_LOG_DIR/comp_ocid_err
      continue
    else
      state_set COMPARTMENT_OCID $COMPARTMENT_OCID
      break
    fi
  fi

  if ! test -z "${TEST_COMPARTMENT-}"; then
    COMP="$TEST_COMPARTMENT"
  else
    echo 'Please enter the OCI compartment where you would like the workshop resources to be created.'
    echo 'For an existing compartment, enter the OCID. For a new compartment, enter the name.'
    read -p "Please specify the compartment: " COMP
  fi

  if test -z "$COMP"; then
    echo "ERROR: No compartment specified"
    continue
  fi

  if [[ "$COMP" =~ ocid1.* ]]; then
    # An existing compartment
    COMPARTMENT_OCID="$COMP"
    if ! oci iam compartment get --compartment-id "$COMPARTMENT_OCID" 2>&1 >$DCMS_LOG_DIR/comp_ocid_err; then
      echo "ERROR: The compartment $COMPARTMENT_OCID does not exist.  Please retry."
      cat $DCMS_LOG_DIR/comp_ocid_err
      continue
    else
      state_set COMPARTMENT_OCID $COMPARTMENT_OCID
      break
    fi
  fi

  # New compartment
  if ! test -z "${TEST_PARENT_COMPARTMENT_OCID-}"; then
    PARENT_COMP="$TEST_PARENT_COMPARTMENT_OCID"
  else
    echo 'Please enter the OCID of the compartment in which you would like the new compartment to be created.'
    read -p "Please specify the parent compartment OCID (hit return for the root compartment): " PARENT_COMP
  fi

  if [[ "$PARENT_COMP" =~ ocid1.* ]]; then
    # We have the parent compartment's OCID
    PARENT_COMPARTMENT_OCID="$PARENT_COMP"
  else
    PARENT_COMPARTMENT_OCID="$(state_get TENANCY_OCID)"
  fi

  COMPARTMENT_OCID=`oci iam compartment create --region "$(state_get HOME_REGION)" --compartment-id "$PARENT_COMPARTMENT_OCID" --name "$COMP" --description "GrabDish Workshop $(state_get RUN_NAME)" --query 'data.id' --raw-output`
  state_set COMPARTMENT_OCID $COMPARTMENT_OCID
done

# Wait for the compartment to become active
while ! test `oci iam compartment get --compartment-id "$(state_get COMPARTMENT_OCID)" --query 'data."lifecycle-state"' --raw-output 2>/dev/null`"" == 'ACTIVE'; do
  echo "Waiting for the compartment to become ACTIVE"
  sleep 5
done

# Setup the vault status
if ! DCMS_VAULT_STATUS=$(provisioning-get-status $DCMS_VAULT); then
  echo "ERROR: Unable to get workshop vault status"
  exit 1
fi

case "$DCMS_VAULT_STATUS" in

  applied | byo)
    # Nothing to do
    ;;

  applying)
    # Setup already running so exit
    exit
    ;;

  destroying-failed | destroying | destroyed)
    # Cannot setup during destroy phase
    echo "ERROR: Destroy is running and so cannot run setup"
    exit 1
    ;;

  applying-failed | new)
    # Start or restart the vault setup
    cd $DCMS_VAULT
    cat input.env <<!
COMPARTMENT_OCID='$(state_get COMPARTMENT_OCID)'
BUCKET_NAME='$(state_get RUN_NAME)_vault'
!
    if ! provisioning-apply $MSDD_INFRA_CODE/vault/oci-os; then
      echo "ERROR: Failed to create vault in $DCMS_VAULT"
      exit 1
    fi
    ;;

esac
source $DCMS_VAULT/output.env

# Get the User OCID
while ! state_done USER_OCID; do
  if test -z "${TEST_USER_OCID-}"; then
    echo "Your user's OCID has a name beginning ocid1.user.oc1.."
    read -p "Please enter your OCI user's OCID: " USER_OCID
  else
    USER_OCID=${TEST_USER_OCID-}
  fi
  # Validate
  if test ""`oci iam user get --user-id "$USER_OCID" --query 'data."lifecycle-state"' --raw-output 2>$DCMS_LOG_DIR/user_ocid_err` == 'ACTIVE'; then
    state_set USER_OCID "$USER_OCID"
  else
    echo "That user OCID could not be validated"
    cat $DCMS_LOG_DIR/user_ocid_err
  fi
done

# Get User Name
while ! state_done USER_NAME; do
  USER_NAME=`oci iam user get --user-id "$(state_get USER_OCID)" --query "data.name" --raw-output`
  state_set USER_NAME "$USER_NAME"
done

# OCI Region
while ! state_done OCI_REGION; do
  if test -z "$OCI_REGION"; then
    if test 1 -eq `oci iam region-subscription list --query 'length(data[])' --raw-output`; then
      # Only one subcribed region so must be home region
      OCI_REGION="$(state_get HOME_REGION)"
    else
      read -p "Please enter the name of the region that you are connected to: " OCI_REGION
    fi
  fi
  state_set OCI_REGION "$OCI_REGION"
done

# Get Namespace
while ! state_done NAMESPACE; do
  NAMESPACE=`oci os ns get --compartment-id "$(state_get COMPARTMENT_OCID)" --query "data" --raw-output`
  state_set NAMESPACE "$NAMESPACE"
done

# Auth Token Desc (used for destroy)
if ! state_done DOCKER_AUTH_TOKEN_DESC; then
  state_set DOCKER_AUTH_TOKEN_DESC "grabdish docker login $(state_get RUN_NAME)"
fi

# Get the docker auth token
while ! is_secret_set DOCKER_AUTH_TOKEN; do
  if test $(state_get RUN_TYPE) != "LL"; then
    if ! TOKEN=`oci iam auth-token create --region "$(state_get HOME_REGION)" --user-id "$(state_get USER_OCID)" --description "$(state_get DOCKER_AUTH_TOKEN_DESC)" --query 'data.token' --raw-output 2>$DCMS_LOG_DIR/docker_auth_token`; then
      if grep UserCapacityExceeded $DCMS_LOG_DIR/docker_auth_token >/dev/null; then
        # The key already exists
        echo 'ERROR: Failed to create auth token.  Please delete an old token from the OCI Console (Profile -> User Settings -> Auth Tokens).'
        read -p "Hit return when you are ready to retry?"
        continue
      else
        echo "ERROR: Creating auth token has failed:"
        cat $DCMS_LOG_DIR/docker_auth_token
        exit
      fi
    fi
  else
    read -s -r -p "Please generate an Auth Token and enter the value: " TOKEN
    echo
    echo "Auth Token entry accepted.  Attempting docker login."
  fi
  set_secret DOCKER_AUTH_TOKEN "$TOKEN"
done

# Login to docker
while ! state_done DOCKER_REGISTRY; do
  RETRIES=0
  while test $RETRIES -le 30; do
    if echo "$(get_secret DOCKER_AUTH_TOKEN)" | docker login -u "$(state_get NAMESPACE)/$(state_get USER_NAME)" --password-stdin "$(state_get OCI_REGION).ocir.io" &>/dev/null; then
      echo "Docker login completed"
      state_set DOCKER_REGISTRY "$(state_get OCI_REGION).ocir.io/$(state_get NAMESPACE)/$(state_get RUN_NAME)"
      break
    else
      # echo "Docker login failed.  Retrying"
      RETRIES=$((RETRIES+1))
      sleep 5
    fi
  done
done

# Collect DB password
if ! is_secret_set DB_PASSWORD; then
  echo
  echo 'Database passwords must be 12 to 30 characters and contain at least one uppercase letter,'
  echo 'one lowercase letter, and one number. The password cannot contain the double quote (")'
  echo 'character or the word "admin".'
  echo

  while true; do
    if test -z "${TEST_DB_PASSWORD-}"; then
      read -s -r -p "Enter the password to be used for the order and inventory databases: " PW
    else
      PW="${TEST_DB_PASSWORD-}"
    fi
    if [[ ${#PW} -ge 12 && ${#PW} -le 30 && "$PW" =~ [A-Z] && "$PW" =~ [a-z] && "$PW" =~ [0-9] && "$PW" != *admin* && "$PW" != *'"'* ]]; then
      echo
      break
    else
      echo "Invalid Password, please retry"
    fi
  done
  set_secret DB_PASSWORD $PW
  state_set DB_PASSWORD_SECRET "DB_PASSWORD"
fi

# Collect UI password
if ! is_secret_set UI_PASSWORD; then
  echo
  echo 'UI passwords must be 8 to 30 characters'
  echo

  while true; do
    if test -z "${TEST_UI_PASSWORD-}"; then
      read -s -r -p "Enter the password to be used for accessing the UI: " PW
    else
      PW="${TEST_UI_PASSWORD-}"
    fi
    if [[ ${#PW} -ge 8 && ${#PW} -le 30 ]]; then
      echo
      break
    else
      echo "Invalid Password, please retry"
    fi
  done
  set_secret UI_PASSWORD $PW
  state_set UI_PASSWORD_SECRET "UI_PASSWORD"
fi

# Run the setup in the background
cd $DCMS_STATE
echo "Setup running in background.  Call 'status' to get the status of the setup"
nohup bash -c "provisioning-apply $MSDD_WORKSHOP_CODE/$DCMS_WORKSHOP/config" >>$DCMS_LOG_DIR/setup.log 2>&1 &
