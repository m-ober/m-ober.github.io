---
title: "Manipulating SVGs using JS - Did I hit a bug in Firefox?"
date: 2023-03-26T21:11:51+02:00
tags: ['coding', 'wtf']
draft: true
slug: "manipulating-svgs-using-js-did-i-hit-a-bug-in-firefox"
---
So I have a page where I manipulate an SVG using JavaScript:
<!--more-->


```javascript
const elements = document.querySelectorAll('[data-open-since]');
elements.forEach(function(element) {
    if (/* some condition */) {
        element.classList.remove('no-notification');
        element.classList.add('delayed-notification');
    }
});
```

The stylesheet looks something like:

```css
.delayed-notification {
  fill: none;
  stroke: #e22948;
  animation: pulse-animation-opacity 0.5s alternate infinite;
}

@keyframes pulse-animation-opacity {
  0% {
    opacity: 0;
  }
  100% {
    opacity: 100%;
  }
}
```

The SVG is periodically updated, and the above JavaScript is rerun to
add the class `delayed-notification` where the condition is met.

Everything was fine in Opera and Chrome - but in Firefox I observed
a strange behaviour: After the SVG was refreshed, the animation would stop
until I moved my mouse inside the tab. Then the animation would start again,
but only until the next refresh.

I looked up ways to force a redraw of an object, but this did not help.
Then I thought: Maybe Firefox has a problem with animations starting
while not active, so I swapped the `0` and `100%` in the above CSS snippet.
I expected to now have a static border color of `#e22948` until Firefox
detects activity.

Even better: The animation now just works as expected. No matter if Firefox
is active or not, no matter if I move the mouse or not - the animation works
even after the SVG is reloaded.
