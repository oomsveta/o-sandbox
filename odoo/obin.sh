#!/usr/bin/env bash
# odoo-bin of the task the current folder is in, with that task's config
# (see task.sh): its addons, database and ports. Outside of a task: the main
# checkout's, with $ODOO_RC (/etc/odoo/odoo.conf by default).
#
# Running a task's ./odoo-bin directly would use $ODOO_RC, i.e. the main
# checkouts' addons and the main database: always go through obin.

TASKS=/odoo/tasks

task_dir=
case $PWD/ in
    "$TASKS"/*/*) task_dir=$TASKS/$(echo "${PWD#"$TASKS"/}" | cut -d/ -f1) ;;
esac
# Not in a task's folder, but in a session started in one (ODOO_RC set by
# its .claude/settings.local.json).
if [ -z "$task_dir" ]; then
    case ${ODOO_RC:-} in
        "$TASKS"/*/odoo.conf) task_dir=$(dirname "$ODOO_RC") ;;
    esac
fi

if [ -n "$task_dir" ]; then
    if [ ! -f "$task_dir/odoo.conf" ]; then
        echo "obin: $task_dir isn't a task (no odoo.conf)" >&2
        exit 1
    fi
    export ODOO_RC=$task_dir/odoo.conf
    exec "$task_dir/community/odoo-bin" "$@"
fi
exec /odoo/community/odoo-bin "$@"
