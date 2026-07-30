#!/usr/bin/env bash
# Rebase our Invidious fork onto upstream, rebuild, deploy, and verify.
#
# This is THE way the deployed Invidious image is produced. There is one tree
# (this one) and one branch (nedworks/integration) = upstream + our patches,
# kept in step by rebase. Never build from /usr/local/src/invidious-build: doing
# that on 2026-07-23 produced an image from plain upstream master, silently
# dropping every local patch, and captions stayed broken for a week.
#
#   ./nedworks-rebuild.sh              # rebase onto origin/master, build, deploy
#   ./nedworks-rebuild.sh <commit>     # rebase onto a specific upstream commit
#   ./nedworks-rebuild.sh --no-deploy  # build only
#
# Rebasing onto a specific commit is preferred when adopting a hotfix: it keeps
# the delta from the previously running image auditable (only our patches differ).

set -euo pipefail

BRANCH="nedworks/integration"
TREE="/var/data/config/invidious-build"
COMPOSE="/var/data/config/invidious/docker-compose.yml"
TAG="nedworks/invidious:$(date +%Y.%m.%d)-allfixes"

DEPLOY=1
TARGET="origin/master"
for arg in "$@"; do
    case "$arg" in
        --no-deploy) DEPLOY=0 ;;
        -*) echo "unknown flag: $arg" >&2; exit 2 ;;
        *) TARGET="$arg" ;;
    esac
done

cd "$TREE"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "!! working tree is dirty; commit or stash first" >&2
    git status --short >&2
    exit 1
fi

echo "==> fetching upstream"
git fetch origin master --tags

git checkout "$BRANCH"
BEFORE_PATCHES=$(git log --oneline "$(git merge-base HEAD origin/master)..HEAD" | wc -l)
echo "==> our patch set before rebase: $BEFORE_PATCHES commits"

echo "==> rebasing $BRANCH onto $TARGET"
if ! git rebase "$TARGET"; then
    cat >&2 <<'MSG'
!! rebase hit a conflict.
   Resolve it, `git rebase --continue`, then re-run this script.
   If a patch has been fixed upstream, drop it with `git rebase --skip` and
   remove it from the list in docker-compose.yml.
MSG
    exit 1
fi

AFTER_PATCHES=$(git log --oneline "origin/master..HEAD" | wc -l)
echo "==> our patch set after rebase:  $AFTER_PATCHES commits"
if [[ "$AFTER_PATCHES" -lt "$BEFORE_PATCHES" ]]; then
    echo "!! patch count dropped ($BEFORE_PATCHES -> $AFTER_PATCHES). A patch was" >&2
    echo "   lost or landed upstream. Confirm intentionally before deploying." >&2
    exit 1
fi
git --no-pager log --oneline origin/master..HEAD

echo "==> building $TAG (crystal static release; takes ~10 min)"
DOCKER_BUILDKIT=1 docker build \
    -f docker/Dockerfile.nedworks \
    -t "$TAG" \
    --build-arg release=1 .

if [[ "$DEPLOY" -eq 0 ]]; then
    echo "==> built $TAG (not deployed). Point $COMPOSE at it when ready."
    exit 0
fi

echo "==> pointing compose at $TAG"
sed -i -E "s|^(\s*)image: nedworks/invidious:.*|\1image: ${TAG}|" "$COMPOSE"
grep -nE "^\s*image: nedworks/invidious:" "$COMPOSE"

echo "==> deploying"
docker compose -f "$COMPOSE" up -d invidious

echo "==> waiting for health"
until docker compose -f "$COMPOSE" ps invidious --format '{{.Health}}' | grep -q healthy; do
    sleep 3
done

echo "==> PROVENANCE CHECK (must report branch $BRANCH)"
STATS=$(docker exec owntube node -e \
    "fetch('http://invidious:3000/api/v1/stats').then(r=>r.json()).then(j=>console.log(JSON.stringify(j.software)))")
echo "    $STATS"
if ! grep -q "\"branch\":\"$BRANCH\"" <<<"$STATS"; then
    echo "!! running image does NOT report $BRANCH — it was built from the wrong" >&2
    echo "   tree/branch and is missing our patches. Roll back." >&2
    exit 1
fi

echo "==> pushing branch so the image stays reproducible"
git push --force-with-lease fork "$BRANCH"

cat <<MSG

==> done. $TAG deployed and verified.
    Patches carried: $AFTER_PATCHES (see git log origin/master..$BRANCH)
    Rollback: point image: in $COMPOSE at a previous tag + \`up -d invidious\`.
MSG
