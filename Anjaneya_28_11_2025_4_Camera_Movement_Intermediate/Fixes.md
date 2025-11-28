Question
Camera movement  - forward, backward, left and right are sluggish.
Why is that ?

Answer
Because of **where you call `update()` in your main loop.**

In your code the loop looks essentially like this (simplified):

```cpp
while (!bDone)
{
    if (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT)
            bDone = true;
        else
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }
    else
    {
        display();
        update();   // <-- camera movement happens only here
    }
}
```

That `if/else` structure means:

* `update()` (and therefore all the `GetAsyncKeyState` WASD camera code)
  **runs only when the Windows message queue is empty**.
* When you hold down keys or move the mouse, Windows keeps generating messages
  (`WM_KEYDOWN` auto‑repeat, `WM_MOUSEMOVE`, etc.), so the queue often **isn’t empty**.
* While there are messages pending, you **don’t call `update()` at all**, so:

  * camera position is updated less often than you expect,
  * movement becomes **jerky and sluggish / unresponsive** even though your speed values look reasonable.

That’s why forward/back/left/right feel “sticky” or laggy.

---

### How to fix it

Change the loop so you *always* update and render once per outer loop iteration, and process **all** pending messages first:

```cpp
while (!bDone)
{
    // Drain the message queue
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT)
        {
            bDone = true;
            break;
        }

        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    if (bDone)
        break;

    if (gbActive && !gbWindowMinimize)
    {
        update();   // camera movement every frame
        display();
    }
}
```

With this pattern:

* `update()` runs every frame, independent of how many key/mouse messages you get.
* Your `deltaSeconds` logic and `gCameraMoveSpeed` now behave as intended.
* Camera motion (W/A/S/D) will feel smooth and responsive instead of sluggish.
