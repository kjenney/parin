/// This example shows how to build a Super Mario Bros.-style platformer with Parin.
///
/// It demonstrates the box physics engine (`BoxWorld` / `BoxMover`) used for a
/// tile-based level, a scrolling camera, enemy AI (walkers and a pipe plant),
/// collectibles, bumpable question blocks, a "momentum jump" where running
/// faster makes you jump higher, and a simple state machine for death /
/// victory / game over.
///
/// Controls:
///   Arrow keys / WASD   Move and jump (up or space to jump)
///   R                   Restart the level
///
/// Everything is drawn procedurally with `drawRect` / `drawText`, so the
/// example does not depend on any texture assets.

import parin;

// ==========================================================================
//  Palette
// ==========================================================================
auto marioSky     = Rgba(0x5C, 0x9E, 0xF0);
auto marioRed     = Rgba(0xE0, 0x3B, 0x1B);
auto marioSkin    = Rgba(0xFB, 0xC2, 0x8B);
auto marioHair    = Rgba(0x5A, 0x2E, 0x14);
auto marioBlue    = Rgba(0x24, 0x57, 0xE6);
auto groundDirt   = Rgba(0xC2, 0x8A, 0x4A);
auto groundDark   = Rgba(0x8A, 0x5A, 0x2E);
auto grassGreen   = Rgba(0x4C, 0xB0, 0x4C);
auto grassDark    = Rgba(0x2E, 0x7A, 0x2E);
auto brickRed     = Rgba(0xC6, 0x4A, 0x2A);
auto brickMortar  = Rgba(0x7A, 0x2E, 0x18);
auto qBlock       = Rgba(0xF5, 0xC5, 0x1A);
auto qBlockDark   = Rgba(0xB5, 0x84, 0x10);
auto usedBlock    = Rgba(0x8A, 0x6A, 0x42);
auto stone        = Rgba(0x9A, 0x9A, 0xA2);
auto stoneDark    = Rgba(0x5A, 0x5A, 0x64);
auto pipeGreen    = Rgba(0x3C, 0xB0, 0x44);
auto pipeDark     = Rgba(0x24, 0x78, 0x2C);
auto pipeLight    = Rgba(0x6C, 0xD0, 0x74);
auto poleGray     = Rgba(0xB8, 0xC0, 0xC8);
auto gold         = Rgba(0xF5, 0xD5, 0x4A);
auto coinYellow   = Rgba(0xF5, 0xC5, 0x1A);
auto goombaBody   = Rgba(0x9A, 0x5A, 0x2A);
auto goombaFeet   = Rgba(0x4A, 0x2A, 0x12);
auto plantGreen   = Rgba(0x4C, 0xB0, 0x4C);
auto plantRed     = Rgba(0xE0, 0x3B, 0x1B);
auto hudWhite     = Rgba(0xFC, 0xF8, 0xEA);

// ==========================================================================
//  Level definition
// ==========================================================================
// A simple ASCII level. Each character is one 16x16 tile.
//   '.' air      'X' ground      'B' brick        '?' question block
//   'S' stone    '|' pipe body   'T' pipe top     'F' flag pole
//   'C' coin     'G' goomba      'Y' pipe plant   'P' player start
enum levelMap = [
    "..........................................................................................",
    "..........................................................................................",
    "..........................................................................................",
    "..........................................................................................",
    "....................................................................................F.....",
    "....................................................................................F.....",
    "....................................................................................F.....",
    ".....................CCC.......................................................S....F.....",
    "..............................................................................SS....F.....",
    "................?...BB?BB.........................YY....||...................SSS....F.....",
    "..................................................TT....TT..................SSSS....F.....",
    "............................................TT....||....||.................SSSSS....F.....",
    "..P...............G......................G..||....||....||..G............GSSSSSS....S.....",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..XXXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..XXXXXXXXXXXXXXXXXXXXXXXXX",
];

enum TileKind : int {
    air,
    ground,
    brick,
    question,
    questionUsed,
    stone,
    pipeTop,
    pipeBody,
    flag,
}

enum tile       = 16;
enum flagCol    = 84;
enum startRow   = 13;   // the topmost ground row (player / enemies stand on this)
enum timeLimit  = 300;

// Player physics (frame based, tuned for a floaty, Mario-like jump).
enum runSpeed   = 1.7;
enum accel      = 0.2;
enum gravity    = 0.22;
enum jump       = 5.0;
enum jumpBonus  = 1.5f;  // extra jump velocity when running at full speed.
enum goombaSpeed = 0.5;
enum plantCycle = 2.6f;  // seconds for a full rise / hold / retract / hide cycle.
enum plantMaxH  = 28.0f; // max height the plant reaches above its pipe lip.

// ==========================================================================
//  Entity types
// ==========================================================================
struct Goomba {
    BoxActorId id;
    float dir;       // -1 or 1, walking direction.
    float vy;        // vertical velocity.
    bool alive;
    bool squished;
    float squishT;
}

struct Piranha {
    float cx;      // horizontal center of the plant (pixels).
    float baseY;   // top of the pipe lip; the plant rises from here.
    float t;       // cycle phase, 0..1.
}

struct Coin {
    int col;
    int row;
    bool taken;
}

struct Bump {
    int col;
    int row;
    float t;         // 1 -> 0, drives the "pop" animation.
}

struct CoinPop {
    float x;
    float y;
    float vy;
    float t;         // 1 -> 0, lifetime.
}

// ==========================================================================
//  Game state
// ==========================================================================
auto world      = BoxWorld();
auto player     = BoxActorId();
auto playerMover = BoxMover(runSpeed, accel, gravity, jump);
auto camera     = Camera(0, 0, true);

int levelRows;
int levelCols;
int[] level;                 // flat row-major grid of TileKind values.
int levelWidth;
int levelHeight;
int playerW  = 10;
int playerH  = 14;
int playerStartCol = 2;

List!Vec2  goombaStarts;
List!Goomba goombas;
List!Piranha piranhas;
List!Coin  coins;
List!Bump  bumps;
List!CoinPop coinPops;

int score;
int coinCount;
int lives;
float timeLeft;

enum State { playing, dying, won, gameover }
State state = State.playing;

float deathVy;
float deathT;
Vec2 deathPos;
float wonT;

bool facingRight = true;
bool isOnGround = false;

// ==========================================================================
//  Helpers
// ==========================================================================
int kindAt(int row, int col) {
    if (row < 0 || row >= levelRows || col < 0 || col >= levelCols) return TileKind.air;
    return level[row * levelCols + col];
}

void setKindAt(int row, int col, int kind) {
    if (row < 0 || row >= levelRows || col < 0 || col >= levelCols) return;
    level[row * levelCols + col] = kind;
}

bool isSolid(int kind) {
    return (
        kind == TileKind.ground || kind == TileKind.brick ||
        kind == TileKind.question || kind == TileKind.questionUsed ||
        kind == TileKind.stone || kind == TileKind.pipeTop ||
        kind == TileKind.pipeBody
    );
}

int kindFromChar(char c) {
    switch (c) {
        case 'X': return TileKind.ground;
        case 'B': return TileKind.brick;
        case '?': return TileKind.question;
        case 'S': return TileKind.stone;
        case '|': return TileKind.pipeBody;
        case 'T': return TileKind.pipeTop;
        case 'F': return TileKind.flag;
        default:  return TileKind.air;
    }
}

Vec2 playerCenter() {
    if (state == State.dying) {
        return Vec2(deathPos.x, deathPos.y + playerH * 0.5f);
    }
    if (state == State.won) {
        float slide = min(wonT * 1.4, 1.0);
        float fy = 4 * tile + slide * 10 * tile;
        return Vec2(flagCol * tile + tile * 0.5f, fy + playerH * 0.5f);
    }
    auto p = world.actor(player);
    return Vec2(
        cast(float) (p.position.x + p.size.x * 0.5),
        cast(float) (p.position.y + p.size.y * 0.5),
    );
}

// ==========================================================================
//  Level / world setup
// ==========================================================================
void parseLevel() {
    levelRows = levelMap.length;
    levelCols = levelMap[0].length;
    level = new int[levelRows * levelCols];
    levelWidth  = levelCols * tile;
    levelHeight = levelRows * tile;

    goombaStarts.clear();

    foreach (row; 0 .. levelRows) {
        foreach (col; 0 .. levelCols) {
            char c = levelMap[row][col];
            level[row * levelCols + col] = kindFromChar(c);
            if (c == 'C') coins.push(Coin(col, row, false));
            else if (c == 'G') goombaStarts.push(Vec2(cast(float) (col * tile), cast(float) ((startRow - 1) * tile)));
            else if (c == 'P') playerStartCol = col;
        }
    }

    // Pipe plants: a run of 'Y's on one row becomes a single plant, centered
    // on the pipe and rising from the top of the tile below (the pipe lip).
    piranhas.clear();
    foreach (row; 0 .. levelRows) {
        int col = 0;
        while (col < levelCols) {
            if (levelMap[row][col] != 'Y') {
                col++;
            } else {
                int start = col;
                while (col < levelCols && levelMap[row][col] == 'Y') col++;
                int end = col - 1;
                float cx = cast(float) (start * tile + (end - start + 1) * tile * 0.5);
                float baseY = cast(float) ((row + 1) * tile);
                piranhas.push(Piranha(cx, baseY, 0.0f));
            }
        }
    }
}

void setupWorld() {
    world.clearWalls();
    world.clearActors();

    // Invisible boundary walls so the player cannot leave the level.
    world.pushWall(Box(0, -tile, levelWidth, tile));          // ceiling
    world.pushWall(Box(-tile, 0, tile, levelHeight));         // left
    world.pushWall(Box(levelWidth, 0, tile, levelHeight));    // right

    // Turn every solid tile into a physics wall.
    foreach (row; 0 .. levelRows) {
        foreach (col; 0 .. levelCols) {
            if (isSolid(kindAt(row, col))) {
                world.pushWall(Box(col * tile, row * tile, tile, tile));
            }
        }
    }

    // Player actor, standing on the ground.
    int px = playerStartCol * tile + (tile - playerW) / 2;
    int py = startRow * tile - playerH;
    player = world.pushActor(Box(px, py, playerW, playerH));

    // Goombas.
    goombas.clear();
    foreach (gs; goombaStarts) {
        auto id = world.pushActor(Box(cast(int) gs.x, cast(int) gs.y, tile, tile));
        goombas.push(Goomba(id, -1.0f, 0.0f, true, false, 0.0f));
    }

    // Pipe plants.
    foreach (ref plant; piranhas) plant.t = 0.0f;

    // Reset pickups and effects.
    foreach (ref coin; coins) coin.taken = false;
    bumps.clear();
    coinPops.clear();
}

void resetGame() {
    score = 0;
    coinCount = 0;
    lives = 3;
    timeLeft = timeLimit;
    state = State.playing;
    facingRight = true;
    setupWorld();
}

void killPlayer() {
    if (state != State.playing) return;
    state = State.dying;
    deathVy = -6.0f;
    deathT = 0.0f;
    auto p = world.actor(player);
    deathPos = Vec2(cast(float) p.position.x, cast(float) p.position.y);
    camera.shake(4, 0.3);
}

void winLevel() {
    if (state != State.playing) return;
    state = State.won;
    wonT = 0.0f;
    score += 1000 + cast(int) (timeLeft) * 5; // flag bonus + time bonus.
    camera.shake(3, 0.4);
}

// ==========================================================================
//  Updates
// ==========================================================================
void updatePlayer(float dt) {
    float inputX = wasd.x;
    bool jumpPressed = Keyboard.space.isPressed || wasdPressed.y < 0;

    if (inputX > 0) facingRight = true;
    else if (inputX < 0) facingRight = false;

    // Momentum jump: the faster we are running, the higher we jump.
    float speedRatio = min(abs(playerMover.velocity.x) / runSpeed, 1.0f);
    playerMover.jump = jump + jumpBonus * speedRatio;

    float dirY = (jumpPressed && isOnGround) ? -1.0f : 0.0f;
    auto vel = playerMover.move(Vec2(inputX, dirY));

    // Axis separated movement.
    world.moveActorX(player, vel.x);
    auto hitY = world.moveActorY(player, vel.y);
    bool hitFloor = hitY != boxNoneId && vel.y > 0;
    bool hitCeiling = hitY != boxNoneId && vel.y < 0;
    if (hitFloor) playerMover.velocity.y = 0;

    // Ground detection: probe the pixels just below the player's feet.
    auto p = world.actor(player);
    int pbx = cast(int) p.position.x;
    int pby = cast(int) p.position.y;
    int pbw = cast(int) p.size.x;
    int pbh = cast(int) p.size.y;
    auto probe = Box(pbx, pby + pbh, pbw, 2);
    isOnGround = world.hasWallCollision(probe) != boxNoneId;

    // Bump blocks hit from below while rising.
    if (hitCeiling) {
        int minCol = cast(int) p.position.x / tile;
        int maxCol = cast(int) (p.position.x + p.size.x) / tile;
        int headRow = cast(int) p.position.y / tile;
        foreach (int c; minCol .. maxCol + 1) {
            int kind = kindAt(headRow - 1, c);
            if (kind == TileKind.question) {
                setKindAt(headRow - 1, c, TileKind.questionUsed);
                bumps.push(Bump(c, headRow - 1, 1.0f));
                coinPops.push(CoinPop(c * tile + tile * 0.5f, (headRow - 1) * tile, -3.2f, 1.0f));
                score += 200;
                coinCount += 1;
            } else if (kind == TileKind.brick) {
                bumps.push(Bump(c, headRow - 1, 1.0f));
                score += 50;
            }
        }
    }
}

void updateGoombas(float dt) {
    foreach (ref g; goombas) {
        if (!g.alive) continue;
        if (g.squished) {
            g.squishT -= dt;
            if (g.squishT <= 0) {
                g.alive = false;
                world.removeActor(g.id);
            }
            continue;
        }
        g.vy = min(g.vy + gravity, 6.0f);
        auto hitX = world.moveActorX(g.id, g.dir * goombaSpeed);
        if (hitX != boxNoneId) g.dir = -g.dir;
        auto hitY = world.moveActorY(g.id, g.vy);
        if (hitY != boxNoneId) g.vy = 0;
        if (world.actor(g.id).position.y > levelHeight + tile) {
            g.alive = false;
            world.removeActor(g.id);
        }
    }
}

float piranhaHeight(Piranha plant) {
    // Cycle: rise, hold at full height, retract, hide inside the pipe.
    if (plant.t < 0.25) return (plant.t / 0.25f) * plantMaxH;
    if (plant.t < 0.55) return plantMaxH;
    if (plant.t < 0.80) return (1.0f - (plant.t - 0.55f) / 0.25f) * plantMaxH;
    return 0.0f;
}

void updatePiranhas(float dt) {
    foreach (ref plant; piranhas) {
        plant.t += dt / plantCycle;
        if (plant.t >= 1.0f) plant.t -= 1.0f;
    }
}

void updateEffects(float dt) {
    // Bump animations.
    for (int i = cast(int) (bumps.length - 1); i >= 0; i--) {
        bumps[i].t -= dt * 4.0f;
        if (bumps[i].t <= 0) bumps.remove(cast(Sz) i);
    }
    // Coins popping out of question blocks.
    for (int i = cast(int) (coinPops.length - 1); i >= 0; i--) {
        coinPops[i].vy += 0.4f;
        coinPops[i].y += coinPops[i].vy;
        coinPops[i].t -= dt * 2.0f;
        if (coinPops[i].t <= 0) coinPops.remove(cast(Sz) i);
    }
}

void checkCollisions() {
    auto p = world.actor(player);

    // Coins.
    foreach (ref coin; coins) {
        if (coin.taken) continue;
        auto cbox = Box(coin.col * tile, coin.row * tile, tile, tile);
        if (p.hasIntersection(cbox)) {
            coin.taken = true;
            score += 200;
            coinCount += 1;
        }
    }

    // Goombas: stomp from above, die from the side.
    foreach (ref g; goombas) {
        if (!g.alive || g.squished) continue;
        auto gbox = world.actor(g.id);
        if (p.hasIntersection(gbox)) {
            int pBottom = cast(int) (p.position.y + p.size.y);
            int gTop = cast(int) gbox.position.y;
            if (playerMover.velocity.y > 0 && pBottom < gTop + 10) {
                g.squished = true;
                g.squishT = 0.5;
                playerMover.velocity.y = -3.5f;
                world.moveActorY(player, -3);
                score += 100;
            } else {
                killPlayer();
                return;
            }
        }
    }

    // Pipe plants: they cannot be stomped, touching one kills you.
    foreach (ref plant; piranhas) {
        float h = piranhaHeight(plant);
        if (h < 2.0f) continue;
        auto pbox = Box(cast(int) (plant.cx - 6), cast(int) (plant.baseY - h), 12, cast(int) h);
        if (p.hasIntersection(pbox)) {
            killPlayer();
            return;
        }
    }

    // Flag pole: touching it clears the level.
    auto flagBox = Box(flagCol * tile, 4 * tile, tile, 8 * tile);
    if (p.hasIntersection(flagBox)) {
        winLevel();
        return;
    }

    // Fell into a pit.
    if (p.position.y > levelHeight + tile) killPlayer();
}

void updateCamera(float dt) {
    float half = resolution.x * 0.5f;
    float desired = playerCenter().x - 24.0f; // bias the player left to see ahead.
    camera.position.x = max(half, min(cast(float) levelWidth - half, desired));
    camera.position.y = levelHeight * 0.5f;
    camera.updateShake(dt);
}

// ==========================================================================
//  Drawing
// ==========================================================================
void drawTile(int col, int row) {
    int x = col * tile;
    int y = row * tile;
    int kind = kindAt(row, col);

    // Bump offset: pop the tile up briefly when it is hit.
    int bumpOffset = 0;
    foreach (b; bumps) {
        if (b.col == col && b.row == row) bumpOffset = -cast(int) (sin(b.t * 3.14159) * 6);
    }
    y += bumpOffset;

    switch (kind) {
        case TileKind.ground:
            drawRect(x, y, 16, 16, groundDirt);
            drawRect(x + 2, y + 8, 3, 2, groundDark);
            drawRect(x + 9, y + 12, 3, 2, groundDark);
            if (kindAt(row - 1, col) == TileKind.air) {
                drawRect(x, y, 16, 5, grassGreen);
                drawRect(x, y, 16, 2, grassDark);
                drawRect(x + 3, y - 2, 2, 2, grassGreen);
                drawRect(x + 10, y - 2, 2, 2, grassGreen);
            }
            break;
        case TileKind.brick:
            drawRect(x, y, 16, 16, brickRed);
            drawRect(x, y + 7, 16, 1, brickMortar);
            drawRect(x, y + 15, 16, 1, brickMortar);
            drawRect(x + 7, y, 1, 8, brickMortar);
            drawRect(x + 3, y + 8, 1, 8, brickMortar);
            drawRect(x + 11, y + 8, 1, 8, brickMortar);
            break;
        case TileKind.question:
            drawRect(x, y, 16, 16, qBlock);
            drawRect(x, y, 16, 1, qBlockDark);
            drawRect(x, y + 15, 16, 1, qBlockDark);
            drawRect(x, y, 1, 16, qBlockDark);
            drawRect(x + 15, y, 1, 16, qBlockDark);
            drawText("?", Vec2(x + 8, y + 8), DrawOptions(qBlockDark, Hook.center));
            break;
        case TileKind.questionUsed:
            drawRect(x, y, 16, 16, usedBlock);
            drawRect(x, y, 16, 1, brickMortar);
            drawRect(x, y + 15, 16, 1, brickMortar);
            drawRect(x, y, 1, 16, brickMortar);
            drawRect(x + 15, y, 1, 16, brickMortar);
            break;
        case TileKind.stone:
            drawRect(x, y, 16, 16, stone);
            drawRect(x, y, 16, 1, stoneDark);
            drawRect(x, y + 15, 16, 1, stoneDark);
            drawRect(x, y, 1, 16, stoneDark);
            drawRect(x + 15, y, 1, 16, stoneDark);
            drawRect(x + 3, y + 3, 10, 10, stone);
            break;
        case TileKind.pipeTop:
            drawRect(x - 1, y, 18, 16, pipeGreen);
            drawRect(x - 1, y, 18, 3, pipeLight);
            drawRect(x - 1, y, 18, 1, pipeDark);
            drawRect(x - 1, y + 15, 18, 1, pipeDark);
            drawRect(x - 1, y, 2, 16, pipeDark);
            break;
        case TileKind.pipeBody:
            drawRect(x, y, 16, 16, pipeGreen);
            drawRect(x, y, 3, 16, pipeDark);
            drawRect(x + 13, y, 3, 16, pipeDark);
            drawRect(x + 5, y, 2, 16, pipeLight);
            break;
        case TileKind.flag:
            drawRect(x + 7, y, 2, 16, poleGray);
            if (row == 0 || kindAt(row - 1, col) != TileKind.flag) {
                drawCirc(x + 8, y, 3, gold);                 // ball on top
                drawRect(x + 2, y + 4, 7, 5, marioRed);      // flag cloth
                drawRect(x + 3, y + 5, 5, 1, marioSky);
            }
            break;
        default:
            break;
    }
}

void drawLevel() {
    auto area = camera.area(resolution);
    int minCol = max(0, cast(int) area.position.x / tile);
    int maxCol = min(levelCols - 1, cast(int) (area.position.x + area.size.x) / tile);
    foreach (row; 0 .. levelRows) {
        foreach (col; minCol .. maxCol + 1) {
            if (kindAt(row, col) != TileKind.air) drawTile(col, row);
        }
    }
}

void drawMario(float cx, float cy) {
    float bx = cx - 8;
    float by = cy - 8;
    bool right = facingRight;
    drawRect(bx + 4, by, 8, 2, marioRed);                       // hat
    drawRect(bx + (right ? 5 : 1), by + 1, 10, 1, marioRed);    // brim
    drawRect(bx + 4, by + 2, 8, 3, marioSkin);                  // face
    drawRect(bx + (right ? 9 : 5), by + 2, 1, 1, marioHair);    // eye
    drawRect(bx + (right ? 4 : 10), by + 2, 1, 2, marioHair);   // hair
    drawRect(bx + 4, by + 5, 8, 2, marioRed);                   // shirt
    drawRect(bx + 4, by + 7, 8, 3, marioBlue);                  // overalls
    drawRect(bx + (right ? 12 : 2), by + 5, 2, 2, marioSkin);   // arm
    drawRect(bx + 5, by + 10, 2, 2, marioBlue);                 // legs
    drawRect(bx + 9, by + 10, 2, 2, marioBlue);
    drawRect(bx + (right ? 4 : 3), by + 12, 4, 2, marioHair);   // boots
    drawRect(bx + (right ? 8 : 4), by + 12, 4, 2, marioHair);
}

void drawGoomba(Goomba g) {
    auto b = world.actor(g.id);
    float cx = cast(float) (b.position.x + b.size.x * 0.5);
    float cy = cast(float) (b.position.y + b.size.y * 0.5);
    float bx = cx - 8;
    float by = cy - 8;

    if (g.squished) {
        drawRect(bx + 1, by + 8, 14, 8, goombaBody);
        drawRect(bx + 2, by + 12, 4, 4, goombaFeet);
        drawRect(bx + 10, by + 12, 4, 4, goombaFeet);
        return;
    }

    int step = (cast(int) (elapsedTime * 8) + cast(int) (g.id._data)) % 2;
    drawRect(bx + 4, by, 8, 2, goombaBody);
    drawRect(bx + 2, by + 2, 12, 8, goombaBody);
    drawRect(bx + 4, by + 3, 3, 3, hudWhite);
    drawRect(bx + 9, by + 3, 3, 3, hudWhite);
    drawRect(bx + (g.dir > 0 ? 6 : 4), by + 4, 1, 1, marioHair);
    drawRect(bx + (g.dir > 0 ? 11 : 9), by + 4, 1, 1, marioHair);
    drawRect(bx + (step ? 0 : 1), by + 11, 6, 5, goombaFeet);
    drawRect(bx + 10 - (step ? 0 : 1), by + 11, 6, 5, goombaFeet);
}

void drawPiranha(Piranha plant) {
    float h = piranhaHeight(plant);
    if (h < 1.0f) return;
    float top = plant.baseY - h;
    float headH = min(h, 10.0f);
    if (h > 10.0f) drawRect(plant.cx - 2, top + 10, 4, h - 10, plantGreen); // stem
    drawRect(plant.cx - 6, top, 12, headH, plantRed);                       // head
    if (headH >= 10.0f) {
        drawRect(plant.cx - 4, top + 1, 3, 3, hudWhite);                    // eyes
        drawRect(plant.cx + 1, top + 1, 3, 3, hudWhite);
        drawRect(plant.cx - 3, top + 2, 1, 1, marioHair);                   // pupils
        drawRect(plant.cx + 2, top + 2, 1, 1, marioHair);
        drawRect(plant.cx - 5, top + 6, 10, 2, hudWhite);                   // teeth
        drawRect(plant.cx - 3, top + 6, 1, 2, plantRed);
        drawRect(plant.cx - 1, top + 6, 1, 2, plantRed);
        drawRect(plant.cx + 1, top + 6, 1, 2, plantRed);
        drawRect(plant.cx + 3, top + 6, 1, 2, plantRed);
    }
}

void drawCoin(float x, float y) {
    // Fake a spinning coin by squashing its width over time.
    float s = sin(elapsedTime * 8);
    float w = 3.0f + 4.0f * abs(s);
    drawRect(x + 8 - w * 0.5f, y + 3, w, 10, coinYellow);
    drawRect(x + 8 - w * 0.5f, y + 3, w, 10, gold, 1);
}

void drawEntities() {
    // Coins in the level.
    foreach (ref coin; coins) {
        if (coin.taken) continue;
        drawCoin(coin.col * tile, coin.row * tile);
    }
    // Coins popping from blocks.
    foreach (ref pop; coinPops) {
        drawCoin(pop.x - 8, pop.y);
    }
    // Goombas.
    foreach (ref g; goombas) {
        if (!g.alive) continue;
        drawGoomba(g);
    }
    // Pipe plants.
    foreach (ref plant; piranhas) drawPiranha(plant);
}

void drawHUD() {
    auto opts = DrawOptions(hudWhite);
    drawText("MARIO", Vec2(8, 6), opts);
    drawText("%06d".fmt(score), Vec2(8, 16), opts);
    drawText("COINS", Vec2(104, 6), opts);
    drawText("×%02d".fmt(coinCount), Vec2(104, 16), opts);
    drawText("WORLD", Vec2(184, 6), opts);
    drawText("1-1", Vec2(184, 16), opts);
    drawText("TIME", Vec2(240, 6), opts);
    drawText("%03d".fmt(cast(int) max(0, ceil(timeLeft))), Vec2(240, 16), opts);
    drawText("×%01d LIVES".fmt(lives), Vec2(8, 32), DrawOptions(marioSky, Hook.topLeft));
}

// ==========================================================================
//  Entry point
// ==========================================================================
void ready() {
    lockResolution(320, 240);
    setWindowBackgroundColor(marioSky);
    parseLevel();
    resetGame();
}

bool update(float dt) {
    if (Keyboard.f11.isPressed) toggleIsFullscreen();
    if (Keyboard.r.isPressed) {
        resetGame();
        return false;
    }

    // Effects keep animating in every state.
    updateEffects(dt);

    final switch (state) {
        case State.playing:
            updatePlayer(dt);
            updateGoombas(dt);
            updatePiranhas(dt);
            checkCollisions();
            timeLeft -= dt;
            if (timeLeft <= 0) killPlayer();
            updateCamera(dt);
            break;
        case State.dying:
            deathT += dt;
            deathVy += 0.35f;
            deathPos.y += deathVy;
            updateCamera(dt);
            if (deathT >= 1.3) {
                lives -= 1;
                if (lives <= 0) state = State.gameover;
                else {
                    setupWorld();
                    state = State.playing;
                }
            }
            break;
        case State.won:
            wonT += dt;
            updateCamera(dt);
            break;
        case State.gameover:
            break;
    }

    // ---- Draw the world inside the camera. ----
    with (Attached(camera)) {
        drawLevel();
        drawEntities();

        // Player (position depends on the current state).
        if (state == State.dying) drawMario(deathPos.x + playerW * 0.5f, deathPos.y + playerH * 0.5f);
        else if (state == State.won) {
            float slide = min(wonT * 1.4, 1.0);
            float fy = 4 * tile + slide * 10 * tile;
            drawMario(flagCol * tile + tile * 0.5f, fy + playerH * 0.5f);
        } else {
            auto p = world.actor(player);
            drawMario(
                cast(float) (p.position.x + p.size.x * 0.5),
                cast(float) (p.position.y + p.size.y * 0.5),
            );
        }
    }

    // ---- Draw the HUD and state messages in screen space. ----
    drawHUD();

    if (state == State.won && wonT > 0.6) {
        drawText("COURSE CLEAR!", Vec2(resolution.x * 0.5, 90), DrawOptions(hudWhite, Hook.center));
        drawText("Press R to play again", Vec2(resolution.x * 0.5, 110), DrawOptions(marioSky, Hook.center));
    } else if (state == State.gameover) {
        drawRect(Rect(0, 0, resolution), Rgba(0, 0, 0, 160));
        drawText("GAME OVER", Vec2(resolution.x * 0.5, 90), DrawOptions(hudWhite, Hook.center));
        drawText("Press R to try again", Vec2(resolution.x * 0.5, 110), DrawOptions(marioSky, Hook.center));
    }

    return false;
}

mixin runGame!(ready, update, null);
