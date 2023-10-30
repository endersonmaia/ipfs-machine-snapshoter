#!/usr/bin/env bash

chown -R cartesi:cartesi $SNAPSHOT_DIR

DAPP_CONTRACT_ADDRESS=$(jq -r '.address | ascii_downcase' $DAPP_CONTRACT_ADDRESS_FILE)
SNAP_REDIS_CID_KEY="{chain-${CHAIN_ID-1}:dapp-${DAPP_CONTRACT_ADDRESS:2}}:last-snapshot-cid"
SNAP_REDIS_IPNS_KEY="{chain-${CHAIN_ID-1}:dapp-${DAPP_CONTRACT_ADDRESS:2}}:ipns"

IPFS_API=$(getent ahostsv4 ipfs | awk '{ print $1 }' | head -n 1)
IPFS_CMD="ipfs --api=/ip4/$IPFS_API/tcp/5001"

###
### DOWNLOAD THE LATEST SNAPSHOT FROM IPFS IF AVAILABLE
### AND PROVISION IT TO THE SERVER-MANAGER
(
tmpdir=$(mktemp -d)
printf "📥 checking if latest snapshot is available "
last_snapshot=$(redis-cli -h redis GET $SNAP_REDIS_IPNS_KEY)
if [ ! -z "$last_snapshot" ]; then
    printf "✅\n"
else
    printf "❌\n"
    printf "📥 no latest snapshot available\n"
    exit 0
fi

# FIXME: do not download if the snapshot (same hash) is already in place
printf "📥 downloading latest snapshot from ipfs: %s " $last_snapshot
$IPFS_CMD get --progress=false --output "$tmpdir" "$last_snapshot/metadata.json" 2>&1 > /dev/null
if [ "$?" == "0" ]; then
    metadata_path="$tmpdir/metadata.json"
    epoch_number=$(jq -r '.epochNumber' "$metadata_path")
    input_number=$(jq -r '.inputNumber' "$metadata_path")
    snapshot_path=$SNAPSHOT_DIR/$epoch_number\_$input_number\
    latest_path=$SNAPSHOT_DIR/latest
    rm -f $latest_path
    rm -rf $snapshot_path
    mkdir -p $snapshot_path
    ln -s $snapshot_path $latest_path
    $IPFS_CMD get --progress=false --output $snapshot_path $last_snapshot 2>&1 > /dev/null
    if [ "$?" == "0" ]; then
        printf "to %s ✅\n" $snapshot_path
    fi
fi
)

# signal validator is ready to start
mkdir -p /opt/cartesi/share
echo ok > /opt/cartesi/share/snapshoter.status

# cleanup
printf "🧹 cleaning up "
rm -rf "$tmpdir"
if [ "$?" == "0" ]; then
    printf "✅\n"
fi

###
### WATCH FOR NEW SNAPSHOTS ANDN UPLOAD THEM TO THE IPFS NETWORK
### REGISTERING THE CID TO THE REDIS DATABASE
printf "📍 waiting for new snapshots at %s ...\n" $SNAPSHOT_DIR
inotifywait -r -q -m -P -e create "$SNAPSHOT_DIR" |
    while read path action file; do
        if [ $(basename $file) == "latest" ] ; then
            snapshot_id=$(basename $(readlink -qn $path/$file))
            epoch_number=${snapshot_id%_*}
            input_number=${snapshot_id#*_}
            machine_hash=$(xxd -c 256 -p $path/$file/hash)

            # addd previous snapshot cid to metadata
            printf "📥 checking if previous snapshot exists "
            previous_snapshot_json=""
            previous_snapshot=$(redis-cli -h redis GET $SNAP_REDIS_CID_KEY)
            if [ ! -z "${previous_snapshot:6}" ]; then
                previous_snapshot_json_element=",\"previousSnapshotCID\": \"${previous_snapshot:6}\""
                printf "✅\n"
            else
                printf "❌\n"
                printf "📥 no previous snapshot available\n"
            fi

            metadata="{\"epochNumber\": $epoch_number,\"inputNumber\": $input_number,\"machineHash\": \"$machine_hash\"$previous_snapshot_json_element}"
            printf "📷 new snapshot found %s\n" "$metadata"

            # create CAR file from snapshot
            printf "📦 creating CAR file: %s " "$carfile"
            tmpdir=$(mktemp -d)
            carfile="$tmpdir/$snapshot_id-snapshot.car"
            (
            cd "$path/$snapshot_id/"

            echo $metadata > ./metadata.json

            car create  \
                --version 1 \
                --file "$carfile" \
                *
            )
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # verify CAR file and get its CID
            printf "📦 verifying CAR file "
            car verify "$carfile"
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # save and print CID
            cid=$(car root "$carfile")
            printf "📦 CID: %s\n" "$cid"

            # upload CAR file to IPFS
            printf "📤 uploading CAR file to IPFS "
            $IPFS_CMD dag import \
                --silent \
                "$carfile"
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # register last cid to redis
            printf "📝 saving cid to redis: %s => %s " $SNAP_REDIS_CID_KEY $cid
            (echo -n "/ipfs/$cid" | redis-cli -h redis -x SET $SNAP_REDIS_CID_KEY > /dev/null)
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # create key if it doesn't exists
            $IPFS_CMD key list | grep -q $CHAIN_ID-$DAPP_CONTRACT_ADDRESS
            if [ "$?" == "0" ]; then
                printf "🔑 ipfs key already exists: %s\n" "$CHAIN_ID-$DAPP_CONTRACT_ADDRESS"
            else
                printf "🔑 creating ipfs key: %s " "$CHAIN_ID-$DAPP_CONTRACT_ADDRESS"
                ipns_key=$($IPFS_CMD key gen \
                    --type=rsa \
                    --size=2048 \
                    "$CHAIN_ID-$DAPP_CONTRACT_ADDRESS")
                if [ "$?" == "0" ]; then
                    printf "✅\n"
                fi
            fi

            # update ipns regisry
            printf "📝 publishing ipns name "
            ipns=$($IPFS_CMD name publish --quieter --key=$CHAIN_ID-$DAPP_CONTRACT_ADDRESS --lifetime=8760h "$cid")
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # save ipns to redis
            # TODO: should we check if ipns is already registered
            printf "📝 saving ipns to redis: %s => %s " $SNAP_REDIS_IPNS_KEY $ipns
            (echo -n "/ipns/$ipns" | redis-cli -h redis -x SET $SNAP_REDIS_IPNS_KEY > /dev/null)
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi

            # cleanup
            printf "🧹 cleaning up "
            rm -rf "$tmpdir"
            if [ "$?" == "0" ]; then
                printf "✅\n"
            fi
            chown -R cartesi:cartesi $SNAPSHOT_DIR
        fi
    done
