#!/bin/bash -e

log_level()
{
    case "$1" in
        -e) echo "$(date) [Err]  " ${@:2}
        ;;
        -w) echo "$(date) [Warn] " ${@:2}
        ;;
        -i) echo "$(date) [Info] " ${@:2}
        ;;
        *)  echo "$(date) [Debug] " ${@:2}
        ;;
    esac
}

printUsage()
{
    echo "      Usage:"
    echo "      $FILENAME --identity-file id_rsa --master 192.168.102.34 --user azureuser"
    echo  ""
    echo "            -i, --identity-file                         RSA Private Key file to connect kubernetes master VM, it starts with -----BEGIN RSA PRIVATE KEY-----"
    echo "            -m, --master                                Public ip of Kubernetes cluster master VM. Normally VM name starts with k8s-master- "
    echo "            -u, --user                                  User Name of Kubernetes cluster master VM "
    echo "            -o, --output-file                           Summary file providing result status of the deployment."
    exit 1
}

function final_changes {
    if [ ! -f "$OUTPUT_SUMMARYFILE" ]; then
        printf '{"result":"%s"}\n' "failed" > $OUTPUT_SUMMARYFILE
    fi
}

FILENAME=$0

while [[ "$#" -gt 0 ]]
do
    case $1 in
        -i|--identity-file)
            IDENTITY_FILE="$2"
        ;;
        -m|--master)
            MASTER_IP="$2"
        ;;
        -u|--user)
            USER_NAME="$2"
        ;;
        -o|--output-file)
            OUTPUT_SUMMARYFILE="$2"
        ;;
        *)
            echo ""
            echo "Incorrect parameter $1"
            echo ""
            printUsage
        ;;
    esac
    
    if [ "$#" -ge 2 ]
    then
        shift 2
    else
        shift
    fi
done

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/validate.log"
touch $LOG_FILENAME

{
    log_level -i "------------------------------------------------------------------------"
    log_level -i "Input Parameters"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "IDENTITY_FILE         : $IDENTITY_FILE"
    log_level -i "MASTER_IP             : $MASTER_IP"
    log_level -i "OUTPUT_SUMMARYFILE    : $OUTPUT_SUMMARYFILE"
    log_level -i "USER_NAME             : $USER_NAME"
    log_level -i "------------------------------------------------------------------------"
    
    TEST_DIRECTORY="/home/$USER_NAME/sonobuoy"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "TEST_DIRECTORY           : $TEST_DIRECTORY"
    log_level -i "------------------------------------------------------------------------"
    # Check if Sonobuoy pods are running and up
    i=0
    while [ $i -lt 10 ];do
        sonobuoyPod=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo kubectl get pods --all-namespaces | grep 'sonobuoy' | grep 'Running' || true")
        if [ -z "$sonobuoyPod" ]; then
            log_level -i "Sonobuoy deployment failed or sonobuoy pod is not running. Will retry to see if it is up."
            sleep 30s
        else
            break
        fi
        
        let i=i+1
    done
    
    if [ -z "$sonobuoyPod" ]; then
        log_level -e "Sonobuoy deployment failed or sonobuoy pod is not running."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Sonobuoy deployment failed or sonobuoy pod not reached running state." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Sonobuoy deployment went through fine and it is running."
    fi
    
    # Check Sonobuoy runs are in progress.
    # We will timeout after 3 hours just to make sure we don't end up in infinite loop.
    i=0
    while [ $i -lt 180 ];do
        runStatus=$(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; ./sonobuoy status | grep running || true")
        log_level -i "Status of the run is: $runStatus"
        if [ -z "$runStatus" ]; then
            break
        else
            log_level -i "Runs are still in progress. Will retry again to see if it is still running."
            sleep 60s
        fi
        let i=i+1
    done
    
    runStatus=$(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; ./sonobuoy status | grep running || true")
    log_level -i "Runs status after  $runStatus."
    if [ -z "$runStatus" ]; then
        log_level -i "Runs got over within given time. Will retry again to see if it is still running."
    else
        printf '{"result":"%s","error":"%s"}\n' "failed" "Sonobuoy deployment failed or sonobuoy pod not reached running state." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    # Retrieve test case details.
    
    i=0
    while [ $i -lt 10 ];do
        ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; ./sonobuoy retrieve;"
        tarfile=$(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP 'ls -R | grep _sonobuoy_ | sort -r | head -1')
        if [ -z "$tarfile" ]; then
            log_level -e "No tar file got created. Will retry after some time."
            sleep 30s
        else
            break
        fi
        
        let i=i+1
    done
    
    if [ -z "$tarfile" ]; then
        log_level -e "No tar file got created. Sonobuoy retrieve command failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "No tar file got created. Sonobuoy retrieve command failed." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Retriving test run details from file ($tarfile)."
    fi
    
    resultfolder="${tarfile%.*.*}"
    log_level -i "Copy tar file($tarfile) locally to $OUTPUT_FOLDER"
    scp -r -i $IDENTITY_FILE $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/$tarfile $OUTPUT_FOLDER
    
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_DIRECTORY/$resultfolder"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; sudo tar -xvf $tarfile -C $TEST_DIRECTORY/$resultfolder"
    
    # Todo check if file exist.
    log_level -i "Copy junit file(junit_01.xml) locally to $OUTPUT_FOLDER"
    scp -r -i $IDENTITY_FILE $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/$resultfolder/plugins/e2e/results/junit_01.xml $OUTPUT_FOLDER
    
    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
} 2>&1 | tee $LOG_FILENAME