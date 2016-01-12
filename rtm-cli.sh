#!/bin/bash
#The first two lines of my config are:
#api_key="your key here"
#api_secret="your secret here"
#You'll need this for all of the script.
. ~/.rtmcfg

api_url="https://api.rememberthemilk.com/services/rest/"
#I find json easier to work with, but you can remove it
#from here and in the $standard_args variable and you'll 
#get xml back. For json you'll need to install jq, because 
#this script relies heavily on it.
format="json"
standard_args="api_key=$api_key&format=$format&auth_token=$auth_token"
#You could easily swap this out for `curl -s` if you want.
#I prefer wget for no principled reason.
wget_cmd="wget -q -O -"

#set options
#i could do tags... and i do need to figure that out...
#for now this will grab the list to add your task too.
for i in "$@"
do
case $i in
    -l=*|--list=*)
        list_name=$(echo "${i#*=}")
    shift
    ;;
esac
done

#sign requests, pretty much all api calls need to be signed
#https://www.rememberthemilk.com/services/api/authentication.rtm
get_sig ()
{
    echo -n $api_secret$(echo "$1" | tr '&' '\n' | sort | tr -d '\n' | tr -d '=') | md5sum | cut -d' ' -f1
}

#authorization
#https://www.rememberthemilk.com/services/api/authentication.rtm
#gets the frob and appends it to your .rtmcfg
get_frob () {
    method="rtm.auth.getFrob"
    args="method=$method&$standard_args"
    sig=$(get_sig "$args")
    x=$($wget_cmd "$api_url?$args&api_sig=$sig" | jq -r '.rsp | .frob | @text')
    echo "frob='$x'" >> ~/.rtmcfg
}
#builds the URL for giving permissison for the app to 
#access your account. 
auth_app () {
    auth_url="http://www.rememberthemilk.com/services/auth/"
    perms="delete"
    args="api_key=$api_key&perms=$perms&frob=$frob"
    sig=$(get_sig "$args")
    x-www-browser "$auth_url?$args&api_sig=$sig"
}
#Once the window/tab/whatever is closed, this method is
#called to get the all important auth_token. Which is
#then appended to your .rtmcfg
get_token () {
    method="rtm.auth.getToken"
    args="method=$method&$standard_args&frob=$frob"
    sig=$(get_sig "$args")
    token=$($wget_cmd "$api_url?$args&api_sig=$sig" | jq -r '.rsp | .auth | .token | @text')
    echo "auth_token='$token'" >> ~/.rtmcfg
}

#bundles all the above steps
authenticate () {
    get_frob
    . .rtmcfg
    auth_app
    get_token
}
#this is to check if your auth_token is valid
#use this to troubleshoot if the authentication isn't working.
check_token () {
    method="rtm.auth.checkToken"
    args="method=$method&$standard_args"
    sig=$(get_sig "$args")
    $wget_cmd "$api_url?$args&api_sig=$sig" | jq '.rsp | .stat'
}
#Grabs the timeline. Need for all write requests.
#https://www.rememberthemilk.com/services/api/timelines.rtm
get_timeline () {
    method="rtm.timelines.create"
    args="method=$method&$standard_args"
    sig=$(get_sig "$args")
    timeline=$($wget_cmd "$api_url?$args&api_sig=$sig" | jq -r '.rsp|.timeline')
    echo "timeline=$timeline" >> .rtmcfg
}

#Gets a list of lists.
#https://www.rememberthemilk.com/services/api/methods/rtm.lists.getList.rtm
lists_getList () {
    method="rtm.lists.getList"
    args="method=$method&$standard_args"
    sig=$(get_sig "$args")
    $wget_cmd "$api_url?$args&api_sig=$sig" > /tmp/lists.json
}
#This matches the list name with its ID.
index_lists () {
> /tmp/list-vars.txt
c=0
    x=$(jq '.rsp | .lists | .list | length' /tmp/lists.json)
    while [ $c -lt $x ]
    do
        list_name=$(jq -r ".rsp | .lists | .list[$c] | .name | @text" /tmp/lists.json)
        list_id=$(jq -r ".rsp | .lists | .list[$c] | .id | @text" /tmp/lists.json)
        echo "$list_name=$list_id" | tr -d ' ' >> /tmp/list-vars.txt
    c=$((c+1))
    done 
}

#Grab the tasks and save the json to tmp
#https://www.rememberthemilk.com/services/api/methods/rtm.tasks.getList.rtm
tasks_getList () {
. /tmp/list-vars.txt
    method="rtm.tasks.getList"
    args="method=$method&$standard_args&filter=status:incomplete" #
    sig=$(get_sig "$args")
    $wget_cmd "$api_url?$args&api_sig=$sig" > /tmp/tasks.json
}
#This grabs the useful data from the json file and
#converts it to a csv.
index_tasks () {
> /tmp/tasks.csv
c=0
    x=$(jq '.rsp|.tasks|.list|length' /tmp/tasks.json)
    while [ $c -lt $x ]
    do
        y=$(jq ".rsp|.tasks|.list[$c]|.taskseries|length" /tmp/tasks.json)
        c1=0
        while [ $c1 -lt $y ]
        do
        list=$(jq -r ".rsp|.tasks|.list[$c]|.id" /tmp/tasks.json| xargs -I{} grep {} /tmp/list-vars.txt | cut -d'=' -f1 )
        series_id=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]|.id" /tmp/tasks.json)
        task_id=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]| .task | .id" /tmp/tasks.json)
        name=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]|.name" /tmp/tasks.json)
        priority=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]|.task|.priority" /tmp/tasks.json)
        due=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]|.task|.due" /tmp/tasks.json)
        due_date=$(date --date="$due" +'%D %H:%M')
        tags=$(jq -r ".rsp|.tasks|.list[$c]|.taskseries[$c1]|.tags[]|.tag" /tmp/tasks.json)
        echo "$priority,$due_date,$series_id,$task_id,$list,$name" >> /tmp/tasks.csv
        c1=$((c1+1))
        done
    c=$((c+1))
    done
}
#Bundle the above four steps for one sync.
sync_tasks () {
    lists_getList
    index_lists
    tasks_getList
    index_tasks
}
#this is the default sorting order. First by priority,
#then by due date.
sort_priority () {
    sort -t',' -k1,2 /tmp/tasks.csv > /tmp/by-priority.csv
}
#you can get it sorted by date if you prefer.
sort_date () {
    sort -t',' -k2,1 /tmp/tasks.csv > /tmp/by-date.csv
}
#this creates an 'item' array, so that we can pick the
#exact task we need to complete.
index_csv () {
> /tmp/indexed_tasks.csv
d=1
    while read line
    do
        echo "$line" | sed "s/^/item\[$d\]=\"/g" | sed 's/$/"/g' >> /tmp/indexed_tasks.csv
    d=$((d+1))
    done < $1
}
#this displays your tasks to stdout looking reasonably,
#I think. I want to add colour.
display_tasks () {
c=1
    index_csv $1
    while read line
    do
        pri=$(echo "$line" | cut -d',' -f1 | sed 's/N/\ /g')
        due=$(echo "$line" | cut -d',' -f2)
        due_date=$(date --date="$due" +'%b %d %R' | sed 's/00:00//g')
        name=$(echo "$line" | cut -d',' -f6)
        list=$(echo "$line" | cut -d',' -f5)
        tag==$(echo "$line" | cut -d',' -f7)
        printf "$c: $name $due_date #$list\n"
    c=$((c+1))
    done < /tmp/indexed_tasks.csv
}

#This will mark a task as complete. And this action can
#be undone if you need.
#https://www.rememberthemilk.com/services/api/methods/rtm.tasks.complete.rtm
tasks_complete () {
    method="rtm.tasks.complete"
    x=$(grep "item\[$1\]" /tmp/indexed_tasks.csv | sed "s/item\[$1\]=//g" )
        l_id=$(echo "$x" | cut -d',' -f5 | xargs -I{} grep {} /tmp/list-vars.txt | cut -d'=' -f2)
        ts_id=$(echo "$x" | cut -d',' -f3)
        t_id=$(echo "$x" | cut -d',' -f4)
        args="method=$method&$standard_args&timeline=$timeline&list_id=$l_id&taskseries_id=$ts_id&task_id=$t_id"
    sig=$(get_sig "$args")
    check=$($wget_cmd "$api_url?$args&api_sig=$sig" | jq -r '.rsp | .stat')
    if [ $check == "ok" ]
    then
        echo "Task complete!"
    else
        echo "something bad hapon"
    fi
}
#Add a task. For the sake of... simplicity, its usually
#best to always add to a specific list. Something wonky
#happens atm if there are tasks in the Inbox.
#https://www.rememberthemilk.com/services/api/methods/rtm.tasks.add.rtm
tasks_add () {
    method="rtm.tasks.add"
    l_id=$(echo "$list_name" | xargs -I{} grep {} /tmp/list-vars.txt | cut -d'=' -f2)
    args="method=$method&$standard_args&timeline=$timeline&list_id=$l_id&name=$1&parse=1"
    sig=$(get_sig "$args")
    check=$($wget_cmd "$api_url?$args&api_sig=$sig" | jq -r '.rsp | .stat') 
    if [ $check == "ok" ]
    then
        echo "Task added!"
    else
        echo "something bad hapon"
    fi
}

#does the actions below. i should add a 'help' section.
#Note that it syncs your tasks everytime you add or 
#complete one.
for i in "$@"
do
case $i in
    list)
        sync_tasks
        sort_priority
        display_tasks /tmp/by-priority.csv
    shift
    ;;
    add)
        tasks_add "$2"
    shift
    ;;
    complete)
        tasks_complete "$2"
    shift
    ;;
    sync)
        sync_tasks
    shift
    ;;
    authorize)
        authenticate
        . ~/.rtmcfg
    shift
    ;;
    -d)
        sort_date
        display_tasks /tmp/by-date.csv
    shift
    ;;
esac
done