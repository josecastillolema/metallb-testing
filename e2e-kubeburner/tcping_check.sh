SVC_IP=""
while [[ $SVC_IP == "" ]]
do	
SVC_IP=$(oc get svc -A | grep max-serv-$TEST_JOB_ITERATIONS-1 | grep -iv pending | awk '{print $5}')
done

tmux send-keys -t tcping "tcping $SVC_IP 8080" ENTER
